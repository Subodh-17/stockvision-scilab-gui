// ============================================================================
// gui_app.sce
// -----------------------------------------------------------------------
// Interactive Scilab GUI: Stock Market Analysis & Prediction Studio
//
// An educational tool for exploring how three different predictive models --
// Linear Regression, an AR (autoregressive) time-series model, and
// Exponential Smoothing (Holt's linear trend method) -- behave on real
// stock price data. Pick a dataset, pick a model, drag the train/test split
// slider, and immediately see the fitted chart, accuracy metrics, and a
// next-day BUY/SELL/HOLD signal update. A backtest simulator then answers
// the practical follow-up question: "would actually following this model's
// signals have been worth it?" -- by walking the model's signal through the
// whole test period (with a realistic one-day signal-to-trade lag and
// optional transaction costs) and comparing the resulting portfolio value
// against a simple buy-and-hold baseline.
//
// GUI components used (well beyond the "at least three" minimum):
//   uimenu (File, Help), popupmenu x2 (dataset picker, model picker --
//   see the note above on_model_changed() for why a single popupmenu
//   replaced the model picker's original two radiobuttons), slider
//   (train/test split), checkbox (moving-average overlay, auto-redraws on
//   toggle), edit x5 (buy/sell thresholds, AR lookback, transaction cost,
//   slippage), pushbutton x6 (Run Analysis, Run Backtest, Model Info,
//   Reset, Compare Models, Export Results), frame x5 (panel grouping),
//   text (multiple labels, results display, and a colour-coded
//   BUY/SELL/HOLD indicator -- see on_run_analysis()), and three dedicated
//   chart windows (Run Analysis, Run Backtest, and Compare Models each open
//   their own, entirely separate from this main window -- see
//   CHART_FIGURE_ID / BACKTEST_FIGURE_ID / COMPARE_FIGURE_ID below for why:
//   this main window must never be the target of a clf/scf/xdel call, since
//   that would clear every uicontrol in the app along with any plotted
//   content).
//
// All the actual modeling math lives in model_engine.sce (see that file's
// header) -- this file only builds widgets and wires their callbacks to
// those already-tested functions. No modeling logic is duplicated here.
// Every call into model_engine.sce that can fail on bad input (loading a
// file, fitting a model) is wrapped in try/catch so a malformed CSV or a
// degenerate split shows a friendly popup instead of dumping a raw Scilab
// error to the console.
//
// Run with:  scilab -f gui_app.sce
// (Needs a real display -- see README.md for why this can't be verified
// from a headless/CI environment, and what WAS verified instead.)
//
// REVISION NOTE (this version): added a third model (Exponential Smoothing,
// see model_engine.sce), replaced the two-radiobutton model picker with a
// single popupmenu, added a colour-coded BUY/SELL/HOLD indicator next to
// the Results panel, replaced the Compare/Backtest blocking popups with
// in-panel results text plus (for Compare) a genuine bar-chart window, and
// added gridlines/thicker lines to all three chart windows. Every change
// here was verified as far as this sandboxed environment allows: all
// model_engine.sce logic (including the new Exponential Smoothing
// functions) was run and checked against hand-computed values via
// test_model_engine.sce under scilab-cli. The uicontrol/graphics changes in
// THIS file could not be executed in this particular sandbox -- see
// README.md for the same headless-environment limitation the original
// version of this file already notes above -- so they were written by
// closely following this file's own established, working patterns (the
// dataset popupmenu already here for the model popupmenu; the existing
// plot()/legend()/xtitle() calls for the new chart polish) and, for the two
// pieces of genuinely new graphics-handle code (custom bar-chart tick
// labels, and line-thickness styling), wrapped in try/catch so that if any
// of it behaves unexpectedly on a given Scilab build, the feature still
// works correctly -- just without that specific cosmetic polish -- rather
// than failing.
// ============================================================================

clear;
clc;
exec("model_engine.sce", -1);

// ---------------------------------------------------------------------------
// Figure IDs -- explicitly pinned for the two chart windows so they can
// never collide with the main GUI window. Deliberately large, unusual
// numbers (101, 102) rather than small ones (0, 1, 2, ...) -- the main
// window's own ID is left to Scilab's normal auto-assignment (which
// reliably starts low, at 0 or 1) rather than read back via a
// gui.fig.figure_id property access this app has never actually exercised
// at runtime, so there is nothing here that depends on that working.
// CRITICAL: nothing in this file may ever call clf()/scf()/xdel() on
// gui.fig (the main window). clf() clears a figure's uicontrol children
// along with its plotted content, so calling it on the figure holding
// every button, slider, and panel would destroy the entire GUI the moment
// a chart was drawn or the Reset button was clicked -- exactly the bug
// this separation exists to make structurally impossible.
// ---------------------------------------------------------------------------
global CHART_FIGURE_ID; global BACKTEST_FIGURE_ID; global COMPARE_FIGURE_ID;
CHART_FIGURE_ID = 101;
BACKTEST_FIGURE_ID = 102;
COMPARE_FIGURE_ID = 103;   // dedicated window for the "Compare" bar chart --
                            // same isolation rule as the other two: never
                            // scf/clf'd onto gui.fig.

// Exponential Smoothing (Holt's linear trend) hyperparameters -- fixed
// constants rather than extra GUI edit boxes. alpha=0.3/beta=0.1 are
// commonly-used, moderately-smoothed defaults (see Model Info for this
// model). Deliberately not exposed as separate tunable controls: this app
// already gives the user four real levers (dataset / model / split /
// thresholds), and most people comparing three models via the Compare
// button want a sane default, not another pair of knobs to guess at.
global ES_ALPHA; global ES_BETA;
ES_ALPHA = 0.3;
ES_BETA = 0.1;


// ---------------------------------------------------------------------------
// Global state -- shared between the main script and every callback.
// Scilab uicontrol callbacks execute as top-level strings, so this is the
// standard way to give them access to widget handles and the current
// dataset/model without passing arguments through the callback string.
// ---------------------------------------------------------------------------
global gui;             // struct of all widget handles
global app_state;       // struct of current dataset / model / results

gui = struct();
app_state = struct();
app_state.dataset_files = ["sample_data/tech_growth_stock.csv", ..
                            "sample_data/blue_chip_stock.csv", ..
                            "sample_data/volatile_stock.csv"];
app_state.dataset_labels = ["Tech Growth Stock (synthetic demo data)", ..
                             "Blue Chip Stock (synthetic demo data)", ..
                             "Volatile Stock (synthetic demo data)"];
app_state.custom_csv_path = "";   // set via File > Load Custom CSV...
app_state.data = [];
app_state.model = [];
app_state.model_type = "LR";      // "LR", "AR", or "ES" -- the live model-picker selection
app_state.last_fitted_model_type = "";   // which type app_state.model actually is (see on_run_analysis)
app_state.last_plot = [];         // cached chart data, so the MA checkbox can redraw without a re-fit
app_state.last_results = [];      // canonical last-analysis snapshot, used by Export Results
app_state.last_backtest = [];     // cached for Export Results
app_state.split_ratio = 0.8;
app_state.ar_lookback = 10;
app_state.buy_threshold = 0.5;
app_state.sell_threshold = -0.5;
app_state.transaction_cost_pct = 0;
app_state.slippage_pct = 0;

MODEL_INFO_TEXT = struct();
MODEL_INFO_TEXT("LR") = [
"LINEAR REGRESSION"; " "; ..
"Fits a straight-line (well, straight-hyperplane) relationship"; ..
"between 12 engineered features -- lagged prices, moving"; ..
"averages, volatility, daily return -- and the next closing"; ..
"price. Fast, interpretable (you can read the coefficients),"; ..
"but assumes a fixed linear relationship that does not adapt to"; ..
"changing market regimes."];
MODEL_INFO_TEXT("AR") = [
"AR (AUTOREGRESSIVE) TIME-SERIES MODEL"; " "; ..
"Predicts the next price directly from a window of the last"; ..
"N days of its own closing prices (N = the lookback set in the"; ..
"Thresholds & Costs panel, default 10) -- a genuine sequential"; ..
"model, same SPIRIT as feeding a lookback window into an LSTM."; ..
"But to be precise: this is a LINEAR model fit by ordinary"; ..
"least squares. It is NOT an LSTM -- no gates, no nonlinearity,"; ..
"no learned memory. It captures short-memory momentum patterns"; ..
"the feature-based LR model does not see directly, using plain"; ..
"linear algebra to do it."];
MODEL_INFO_TEXT("ES") = [
"EXPONENTIAL SMOOTHING (HOLT LINEAR TREND METHOD)"; " "; ..
"Keeps a single running LEVEL and TREND estimate that updates"; ..
"day by day as each new price arrives, and forecasts one step"; ..
"ahead as level + trend. Unlike Linear Regression (many engineered"; ..
"features) or AR (a fixed lookback window), this model only ever"; ..
"remembers a running summary of the past, not the raw prices"; ..
"themselves -- closer in spirit to how a simple moving average"; ..
"adapts, but with an explicit trend term as well as a level."; ..
"Smoothing parameters alpha=" + string(ES_ALPHA) + " (level) and beta=" + ..
    string(ES_BETA) + " (trend)"; ..
"are fixed, commonly-used defaults, not fit from this data."];


// ---------------------------------------------------------------------------
// Small shared helpers
// ---------------------------------------------------------------------------
function invalidate_model()
    // Clears whatever was previously fit -- called whenever the dataset or
    // the train/test split changes, so a stale model fit to different data
    // can never silently linger and get backtested or exported.
    global gui app_state
    app_state.model = [];
    app_state.last_fitted_model_type = "";
    app_state.last_plot = [];
    app_state.last_results = [];
    set(gui.results_text, "string", "Run an analysis to see results here.");
endfunction

function val = read_numeric_edit(handle, default_val)
    // Reads a GUI edit box as a number; falls back to default_val (and
    // writes it back into the box so the user can see what was actually
    // used) if the box contains something unparseable, instead of letting
    // garbage input silently propagate into the model.
    s = stripblanks(get(handle, "string"));
    if is_valid_number_string(s) then
        val = strtod(s);
    else
        val = default_val;
        set(handle, "string", string(default_val));
    end
endfunction

function redraw_chart()
    // Redraws the main chart from app_state.last_plot -- shared by
    // on_run_analysis (after a fresh fit) and on_ma_toggle (checkbox flip,
    // no re-fit needed). Always draws into CHART_FIGURE_ID, a dedicated
    // figure window separate from the main GUI window (gui.fig) -- NEVER
    // scf/clf on gui.fig itself, since clf() clears a figure's uicontrol
    // children along with its plotted content, which would wipe out every
    // button, slider, and panel in the app the moment a chart was drawn.
    global gui app_state
    global CHART_FIGURE_ID
    lp = app_state.last_plot;
    scf(CHART_FIGURE_ID);
    clf(CHART_FIGURE_ID);
    plot(1:size(lp.y_test_plot,1), lp.y_test_plot, "k-");
    plot(1:size(lp.y_pred_plot,1), lp.y_pred_plot, "r--");
    legend_entries = ["Actual Price", lp.model_name + " Predicted Price"];

    if get(gui.cb_moving_avg, "value") == 1 then
        ma20 = moving_average(lp.y_test_plot, 20, lp.ma_history);
        plot(1:size(ma20,1), ma20, "b-.");
        legend_entries = [legend_entries, "20-Day Moving Average"];
    end
    xtitle(lp.model_name + " -- Actual vs Predicted (Test Set)", "Time", "Stock Price");
    legend(legend_entries, 2);

    // Visual polish: gridlines + thicker lines read far better in a
    // screenshot/demo than the plain default. Wrapped defensively (see the
    // Compare chart above for the same rationale) -- if the exact handle
    // shape here ever differs on some Scilab build, the chart still renders
    // correctly, just without the extra polish.
    try
        ax = gca();
        ax.grid = [color("light gray") color("light gray")];
        for k = 1:size(ax.children)
            if typeof(ax.children(k)) == "Compound" then
                for c = 1:size(ax.children(k).children)
                    ax.children(k).children(c).thickness = 2;
                end
            end
        end
    catch
    end
endfunction


// ---------------------------------------------------------------------------
// Callback: dataset selector changed -> reload data, don't re-run yet
// ---------------------------------------------------------------------------
function on_dataset_changed()
    global gui app_state
    idx = get(gui.dataset_popup, "value");
    if idx <= size(app_state.dataset_files, 2) then
        path = app_state.dataset_files(idx);
    else
        path = app_state.custom_csv_path;
    end
    if path == "" then
        set(gui.status_text, "string", "No custom CSV loaded yet -- use File > Load Custom CSV...");
        return
    end

    try
        d = load_dataset(path);
    catch
        messagebox(lasterror(), "Could not load CSV", "error");
        set(gui.status_text, "string", "Failed to load dataset -- see popup for details.");
        return
    end

    app_state.data = d;
    invalidate_model();
    msg = "Loaded " + string(d.n) + " rows. Click Run Analysis.";
    if size(d.warnings, 1) > 0 then
        msg = msg + " Note: " + strcat(d.warnings, " ");
    end
    set(gui.status_text, "string", msg);
endfunction


// ---------------------------------------------------------------------------
// Callback: model picker popup changed. A single 3-item popupmenu (rather
// than one radiobutton per model) so a fourth or fifth model could be
// added later without another round of manual layout surgery.
// ---------------------------------------------------------------------------
function on_model_changed()
    global gui app_state
    idx = get(gui.model_popup, "value");
    if idx == 1 then
        app_state.model_type = "LR";
    elseif idx == 2 then
        app_state.model_type = "AR";
    else
        app_state.model_type = "ES";
    end
endfunction


// ---------------------------------------------------------------------------
// Callback: slider moved -> update the live readout label AND invalidate
// whatever model was previously fit (it was fit to the OLD split, and
// silently backtesting/exporting it after the slider moved would be
// misleading).
// ---------------------------------------------------------------------------
function on_slider_moved()
    global gui app_state
    v = get(gui.split_slider, "value");
    app_state.split_ratio = v;
    set(gui.split_label, "string", "Train/Test split: " + string(round(v*100)) + "% / " + ..
        string(round((1-v)*100)) + "%");
    invalidate_model();
    set(gui.status_text, "string", "Split changed -- click Run Analysis to refit.");
endfunction


// ---------------------------------------------------------------------------
// Callback: moving-average checkbox toggled -> redraw immediately using the
// already-computed fit, instead of requiring another Run Analysis click.
// ---------------------------------------------------------------------------
function on_ma_toggle()
    global app_state
    if typeof(app_state.last_plot) == "constant" then
        return   // nothing has been plotted yet -- nothing to redraw
    end
    redraw_chart();
endfunction


// ---------------------------------------------------------------------------
// Callback: "Run Analysis" button -- the main action. Fits the selected
// model, evaluates it, draws the chart, and updates the results panel.
// ---------------------------------------------------------------------------
function on_run_analysis()
    global gui app_state

    if typeof(app_state.data) == "constant" then   // still the placeholder []
        set(gui.status_text, "string", "Pick a dataset first.");
        return
    end

    set(gui.status_text, "string", "Running...");

    app_state.buy_threshold = read_numeric_edit(gui.buy_threshold_edit, 0.5);
    app_state.sell_threshold = read_numeric_edit(gui.sell_threshold_edit, -0.5);
    lb = round(read_numeric_edit(gui.ar_lookback_edit, 10));
    if lb < 2 then lb = 2; end
    set(gui.ar_lookback_edit, "string", string(lb));
    app_state.ar_lookback = lb;
    app_state.transaction_cost_pct = read_numeric_edit(gui.txn_cost_edit, 0);
    app_state.slippage_pct = read_numeric_edit(gui.slippage_edit, 0);

    data = app_state.data;
    current_price = data.close($);

    try
        if app_state.model_type == "LR" then
            feat = build_lr_features(data);
            model = fit_linear_regression(feat, app_state.split_ratio);
            ev = evaluate_model(model);
            [next_price, ci_lo, ci_hi] = predict_next_lr(model);
            y_test_plot = model.y_test;
            y_pred_plot = ev.y_pred;
            ma_history = feat.y(1:model.split_idx);
            model_name = "Linear Regression";
        elseif app_state.model_type == "AR" then
            model = fit_ar_model(data, app_state.ar_lookback, app_state.split_ratio);
            ev = evaluate_ar_model(model);
            [next_price, ci_lo, ci_hi] = predict_next_ar(model);
            y_test_plot = ev.y_test_real;
            y_pred_plot = ev.y_pred;
            ma_history = model.y_train_real;
            model_name = "AR(" + string(app_state.ar_lookback) + ")";
        else   // "ES" -- Exponential Smoothing (Holt's linear trend)
            model = fit_exponential_smoothing(data, app_state.split_ratio, ES_ALPHA, ES_BETA);
            ev = evaluate_es_model(model);
            [next_price, ci_lo, ci_hi] = predict_next_es(model);
            y_test_plot = model.y_test;
            y_pred_plot = ev.y_pred;
            ma_history = data.close(1:model.split_idx);
            model_name = "Exp. Smoothing (a=" + string(ES_ALPHA) + ", b=" + string(ES_BETA) + ")";
        end
    catch
        messagebox(lasterror(), "Analysis failed", "error");
        set(gui.status_text, "string", "Analysis failed -- see popup for details.");
        return
    end

    signal = generate_signal(current_price, next_price, app_state.buy_threshold, app_state.sell_threshold);
    app_state.model = model;
    app_state.last_fitted_model_type = app_state.model_type;

    app_state.last_plot = struct();
    app_state.last_plot.y_test_plot = y_test_plot;
    app_state.last_plot.y_pred_plot = y_pred_plot;
    app_state.last_plot.model_name = model_name;
    app_state.last_plot.ma_history = ma_history;
    redraw_chart();

    // Canonical snapshot of the last analysis -- used both to build the
    // results panel below AND by on_export_results(), so the exported file
    // (CSV/PDF/TXT) always matches exactly what's on screen.
    ds_idx = get(gui.dataset_popup, "value");
    if ds_idx <= size(app_state.dataset_labels, 2) then
        dataset_label = app_state.dataset_labels(ds_idx);
    else
        dataset_label = "Custom: " + app_state.custom_csv_path;
    end

    lr = struct();
    lr.dataset_label = dataset_label;
    lr.model_name = model_name; lr.rows_used = data.n; lr.split_ratio = app_state.split_ratio;
    lr.rmse = ev.rmse; lr.mae = ev.mae; lr.mape = ev.mape; lr.r2 = ev.r2;
    lr.accuracy_pct = ev.accuracy_pct;
    lr.current_price = current_price; lr.next_price = next_price;
    lr.ci_lo = ci_lo; lr.ci_hi = ci_hi;
    lr.pct_change = signal.pct_change; lr.signal_action = signal.action;
    lr.buy_threshold = app_state.buy_threshold; lr.sell_threshold = app_state.sell_threshold;
    app_state.last_results = lr;

    accuracy_str = "n/a";
    if ~isnan(ev.accuracy_pct) then accuracy_str = string(ev.accuracy_pct) + "%"; end

    // --- results panel ---
    results_str = [
        "Dataset: " + dataset_label; ..
        "Model: " + model_name; ..
        "Rows used: " + string(data.n); ..
        "Train/test split: " + string(round(app_state.split_ratio*100)) + "% / " + ..
            string(round((1-app_state.split_ratio)*100)) + "%"; ..
        "-----------------------------"; ..
        "RMSE: " + string(ev.rmse); ..
        "MAE:  " + string(ev.mae); ..
        "MAPE: " + string(ev.mape) + "%"; ..
        "R^2:  " + string(ev.r2); ..
        "Prediction Accuracy: " + accuracy_str; ..
        "-----------------------------"; ..
        "Current price:   " + string(current_price); ..
        "Predicted price: " + string(next_price); ..
        "  (+/-95% band: " + string(ci_lo) + " to " + string(ci_hi) + ..
            " -- a rough normal approximation from residual spread,"; ..
        "   NOT a true statistical prediction interval)"; ..
        "Predicted change: " + string(signal.pct_change) + "%"; ..
        "SIGNAL: " + signal.action + "  (thresholds +" + string(app_state.buy_threshold) + ..
            "% / " + string(app_state.sell_threshold) + "%)"; ..
        "(SELL exits an existing position -- this app never shorts.)"; ..
        "[Informational only -- no real orders are placed.]" ..
    ];
    set(gui.results_text, "string", results_str);
    set(gui.status_text, "string", "Done.");

    // Colored BUY/SELL/HOLD indicator, right next to the "Results" label --
    // the same information is already in the results_str text above, but a
    // color-coded glance is much faster to read than scanning the listbox.
    if signal.action == "BUY" then
        set(gui.label_signal_indicator, "string", "BUY", "foregroundcolor", [0 0.55 0]);
    elseif signal.action == "SELL" then
        set(gui.label_signal_indicator, "string", "SELL", "foregroundcolor", [0.8 0 0]);
    else
        set(gui.label_signal_indicator, "string", "HOLD", "foregroundcolor", [0.45 0.45 0.45]);
    end
endfunction


// ---------------------------------------------------------------------------
// Callback: "Model Info" button -- educational popup explaining the model
// currently selected. This is what ties the app to "educational usefulness"
// rather than just being a black-box predictor.
// ---------------------------------------------------------------------------
function on_model_info()
    global app_state
    messagebox(MODEL_INFO_TEXT(app_state.model_type), "About this model", "info");
endfunction


// ---------------------------------------------------------------------------
// Callback: "Reset" button -- clears results and chart, back to a blank
// slate, including the threshold/lookback/cost edit boxes.
// ---------------------------------------------------------------------------
function on_reset()
    global gui app_state
    global CHART_FIGURE_ID BACKTEST_FIGURE_ID COMPARE_FIGURE_ID
    // Clears the three dedicated CHART windows -- never gui.fig (the main window), which
    // holds every uicontrol in the app and must never be scf/clf'd.
    scf(CHART_FIGURE_ID);
    clf(CHART_FIGURE_ID);
    scf(BACKTEST_FIGURE_ID);
    clf(BACKTEST_FIGURE_ID);
    scf(COMPARE_FIGURE_ID);
    clf(COMPARE_FIGURE_ID);
    invalidate_model();
    app_state.last_backtest = [];
    set(gui.buy_threshold_edit, "string", "0.5");
    set(gui.sell_threshold_edit, "string", "-0.5");
    set(gui.ar_lookback_edit, "string", "10");
    set(gui.txn_cost_edit, "string", "0");
    set(gui.slippage_edit, "string", "0");
    app_state.buy_threshold = 0.5; app_state.sell_threshold = -0.5; app_state.ar_lookback = 10;
    app_state.transaction_cost_pct = 0; app_state.slippage_pct = 0;
    set(gui.label_signal_indicator, "string", "");
    set(gui.results_text, "string", "Run an analysis to see results here.");
    set(gui.status_text, "string", "Reset. Pick a dataset and click Run Analysis.");
endfunction


// ---------------------------------------------------------------------------
// Callback: "Run Backtest" button. Uses whichever model was fit by the most
// recent "Run Analysis" click and simulates following its BUY/SELL/HOLD
// signal through the entire test period (one-day signal-to-trade lag,
// optional transaction cost/slippage from the Thresholds & Costs panel),
// plotted against a buy-and-hold baseline in a dedicated second window
// (kept as a pure plot window with no uicontrols on it at all, to avoid any
// layout risk in the main window).
//
// Deliberately uses app_state.last_fitted_model_type -- a snapshot taken at
// fit time -- rather than the live app_state.model_type popup selection,
// so that changing the model picker AFTER running analysis but
// BEFORE clicking Run Backtest can't cause a mismatch between which model
// is actually stored in app_state.model and which one this function thinks
// it is reading.
// ---------------------------------------------------------------------------
function on_run_backtest()
    global gui app_state
    global BACKTEST_FIGURE_ID

    if typeof(app_state.model) == "constant" then
        set(gui.status_text, "string", "Run an analysis first, then click Run Backtest.");
        return
    end

    model = app_state.model;
    starting_capital = 100000;

    try
        if app_state.last_fitted_model_type == "LR" then
            ev = evaluate_model(model);
            y_actual = model.y_test; y_pred = ev.y_pred;
        elseif app_state.last_fitted_model_type == "AR" then
            ev = evaluate_ar_model(model);
            y_actual = ev.y_test_real; y_pred = ev.y_pred;
        else   // "ES"
            ev = evaluate_es_model(model);
            y_actual = model.y_test; y_pred = ev.y_pred;
        end
        bt = run_backtest(y_actual, y_pred, app_state.buy_threshold, app_state.sell_threshold, ..
                           starting_capital, app_state.transaction_cost_pct, app_state.slippage_pct);
    catch
        messagebox(lasterror(), "Backtest failed", "error");
        set(gui.status_text, "string", "Backtest failed -- see popup for details.");
        return
    end

    app_state.last_backtest = bt;

    // Dedicated backtest figure -- never gui.fig (the main window).
    scf(BACKTEST_FIGURE_ID);
    clf(BACKTEST_FIGURE_ID);
    plot(1:size(bt.strategy_value,1), bt.strategy_value, "b-");
    plot(1:size(bt.buyhold_value,1), bt.buyhold_value, "k--");
    legend(["Model-Guided Strategy", "Buy & Hold"], 2);
    xtitle("Backtest -- Strategy: " + string(round(bt.strategy_final)) + ..
           " (" + string(round(bt.strategy_return_pct)) + "%)   vs   Buy & Hold: " + ..
           string(round(bt.buyhold_final)) + " (" + string(round(bt.buyhold_return_pct)) + "%)", ..
           "Test set day", "Portfolio value (starting capital: " + string(starting_capital) + ")");
    // Same visual polish as the analysis chart -- gridlines + thicker
    // lines -- defensively wrapped for the same reason (see redraw_chart()).
    try
        ax_bt = gca();
        ax_bt.grid = [color("light gray") color("light gray")];
        for k = 1:size(ax_bt.children)
            if typeof(ax_bt.children(k)) == "Compound" then
                for c = 1:size(ax_bt.children(k).children)
                    ax_bt.children(k).children(c).thickness = 2;
                end
            end
        end
    catch
    end

    sharpe_str = "n/a"; if ~isnan(bt.sharpe_ratio) then sharpe_str = string(bt.sharpe_ratio); end
    winrate_str = "n/a"; if ~isnan(bt.win_rate_pct) then winrate_str = string(bt.win_rate_pct) + "%"; end

    summary = [
        "BACKTEST RESULTS"; " "; ..
        "Starting capital: " + string(starting_capital); ..
        "Trades made: " + string(bt.n_trades) + "  (" + string(bt.n_completed_trades) + ..
            " completed round-trip(s))"; ..
        "Transaction cost: " + string(bt.transaction_cost_pct) + "%   Slippage: " + ..
            string(bt.slippage_pct) + "%"; " "; ..
        "Strategy final value:   " + string(bt.strategy_final); ..
        "Strategy total return:  " + string(bt.strategy_return_pct) + "%"; " "; ..
        "Buy & Hold final value: " + string(bt.buyhold_final); ..
        "Buy & Hold total return: " + string(bt.buyhold_return_pct) + "%"; " "; ..
        "--- Risk ---"; ..
        "Max drawdown: " + string(bt.max_drawdown_pct) + "%"; ..
        "Annualized volatility: " + string(bt.volatility_pct_annualized) + "%"; ..
        "Sharpe ratio (rf=0): " + sharpe_str; ..
        "Win rate (completed trades): " + winrate_str; " "; ..
        "[Historical backtest only -- not a guarantee of future performance."; ..
        " Signals take effect one day after they fire (no look-ahead)."; ..
        " SELL exits a position -- this app never shorts.]" ..
    ];
    // Shown in-panel (not a blocking popup) so the person can keep the chart
    // window and this summary both visible side by side, and so a Backtest
    // click doesn't interrupt whatever else they're doing in the window.
    set(gui.results_text, "string", summary);
    set(gui.status_text, "string", "Backtest complete -- see the new chart window and the Results panel.");
endfunction


// ---------------------------------------------------------------------------
// Callback: "Compare Models" button -- fits BOTH models on the current
// dataset/split so they can be judged side by side (single-split metrics
// plus a 3-fold walk-forward mean), instead of having to switch the radio
// button back and forth and remember numbers.
// ---------------------------------------------------------------------------
function on_compare_models()
    global gui app_state
    global COMPARE_FIGURE_ID ES_ALPHA ES_BETA

    if typeof(app_state.data) == "constant" then
        set(gui.status_text, "string", "Pick a dataset first.");
        return
    end

    data = app_state.data;
    lb = round(read_numeric_edit(gui.ar_lookback_edit, 10));
    if lb < 2 then lb = 2; end
    n_folds = 3;

    try
        feat = build_lr_features(data);
        lr_model = fit_linear_regression(feat, app_state.split_ratio);
        lr_eval = evaluate_model(lr_model);

        ar_model = fit_ar_model(data, lb, app_state.split_ratio);
        ar_eval = evaluate_ar_model(ar_model);

        es_model = fit_exponential_smoothing(data, app_state.split_ratio, ES_ALPHA, ES_BETA);
        es_eval = evaluate_es_model(es_model);

        wf_lr = walk_forward_validate(data, "LR", n_folds, lb);
        wf_ar = walk_forward_validate(data, "AR", n_folds, lb);
        wf_es = walk_forward_validate_es(data, n_folds, ES_ALPHA, ES_BETA);
    catch
        messagebox(lasterror(), "Comparison failed", "error");
        set(gui.status_text, "string", "Comparison failed -- see popup for details.");
        return
    end

    // --- bar chart: single-split RMSE side by side with the more
    // trustworthy walk-forward mean RMSE, in a dedicated window so it never
    // has to fight the main window's uicontrols for space. ---
    scf(COMPARE_FIGURE_ID);
    clf(COMPARE_FIGURE_ID);
    model_labels = ["LR"; "AR(" + string(lb) + ")"; "ES"];

    subplot(1, 2, 1);
    bar([lr_eval.rmse; ar_eval.rmse; es_eval.rmse]);
    ax1 = gca();
    // Custom category labels on the x-axis -- wrapped defensively: if this
    // exact tlist form isn't accepted on some Scilab build, the chart still
    // renders correctly with plain numeric x-ticks (1,2,3), just without the
    // "LR/AR/ES" labels -- graceful degradation rather than a broken Compare
    // button over a cosmetic detail.
    try
        ax1.x_ticks = tlist(["ticks", "locations", "labels"], [1;2;3], model_labels);
    catch
    end
    ax1.grid = [color("light gray") color("light gray")];
    xtitle("Single-Split RMSE (lower is better)", "Model", "RMSE");

    subplot(1, 2, 2);
    bar([wf_lr.mean_rmse; wf_ar.mean_rmse; wf_es.mean_rmse]);
    ax2 = gca();
    try
        ax2.x_ticks = tlist(["ticks", "locations", "labels"], [1;2;3], model_labels);
    catch
    end
    ax2.grid = [color("light gray") color("light gray")];
    xtitle(string(n_folds) + "-Fold Walk-Forward Mean RMSE (lower, more trustworthy)", "Model", "RMSE");

    summary = [
        "MODEL COMPARISON"; ..
        "Current split: " + string(round(app_state.split_ratio*100)) + "% / " + ..
            string(round((1-app_state.split_ratio)*100)) + "%"; " "; ..
        "Linear Regression:"; ..
        "  RMSE=" + string(lr_eval.rmse) + "   MAE=" + string(lr_eval.mae) + ..
        "   MAPE=" + string(lr_eval.mape) + "%   R^2=" + string(lr_eval.r2); ..
        "  " + string(n_folds) + "-fold walk-forward: mean RMSE=" + string(wf_lr.mean_rmse) + ..
            "   mean R^2=" + string(wf_lr.mean_r2); " "; ..
        "AR(" + string(lb) + "):"; ..
        "  RMSE=" + string(ar_eval.rmse) + "   MAE=" + string(ar_eval.mae) + ..
        "   MAPE=" + string(ar_eval.mape) + "%   R^2=" + string(ar_eval.r2); ..
        "  " + string(n_folds) + "-fold walk-forward: mean RMSE=" + string(wf_ar.mean_rmse) + ..
            "   mean R^2=" + string(wf_ar.mean_r2); " "; ..
        "Exponential Smoothing (a=" + string(ES_ALPHA) + ", b=" + string(ES_BETA) + "):"; ..
        "  RMSE=" + string(es_eval.rmse) + "   MAE=" + string(es_eval.mae) + ..
        "   MAPE=" + string(es_eval.mape) + "%   R^2=" + string(es_eval.r2); ..
        "  " + string(n_folds) + "-fold walk-forward: mean RMSE=" + string(wf_es.mean_rmse) + ..
            "   mean R^2=" + string(wf_es.mean_r2); " "; ..
        "[Lower RMSE/MAE/MAPE is better. R^2 closer to 1 is better. The"; ..
        " walk-forward numbers are the more trustworthy comparison --"; ..
        " they average over several sequential train/test folds instead"; ..
        " of relying on just one chronological split. See the chart window"; ..
        " for the same numbers side by side.]" ..
    ];
    // In-panel, not a blocking popup -- see the same rationale in
    // on_run_backtest() just above.
    set(gui.results_text, "string", summary);
    set(gui.status_text, "string", "Comparison complete -- see the chart window and the Results panel.");
endfunction


// ---------------------------------------------------------------------------
// Export helpers -- three formats, one canonical data source
// (app_state.last_results / app_state.last_plot / app_state.last_backtest),
// so whichever format the user picks always matches what's on screen.
//
// Robustness fix (this revision): a real run on Scilab 2026.1.0 hit
// "inconsistent row/column dimensions" on CSV export. Root cause: both
// export_results_txt() and export_results_csv() built their output with a
// single big literal vertical concatenation, e.g.
//     lines = [lines; " "; "--- Last Backtest ---"; "Foo: " + string(x); ...]
// This is only ever safe if EVERY piece being stacked is guaranteed to be a
// scalar (1x1) string. Almost all of them are -- but nothing in the code
// actually enforced that, so if any single piece (get(gui.results_text,
// "string") returning multiple rows on some Scilab builds; string() applied
// to a value that isn't a plain scalar; a plot-data field that ends up as a
// row vector instead of a column vector) ever came back with more than one
// row/column, that one non-conforming piece breaks the entire vertical
// concatenation with exactly this error. This was hard to reproduce headlessly
// (100+ real runs here across both models, all 3 datasets, with/without
// backtest, and several splits/costs never hit it -- consistent with it
// depending on a runtime/widget-shape detail that only shows up on certain
// Scilab builds), so the fix does not chase one specific value -- it makes
// the construction structurally immune to this whole class of failure:
//   1. safe_str() forces ANY value (scalar, empty, or an unexpectedly
//      multi-element array) into a guaranteed single-line string. Multi-element
//      input is joined with "; " rather than dropped, so no data is ever lost --
//      it would just be visible as one field packing more than expected.
//   2. append_line() appends exactly ONE already-scalar string onto the
//      accumulator at a time, via safe_str() first. Stacking a guaranteed
//      1x1 onto an Nx1 column can never throw "inconsistent row/column
//      dimensions" -- so the failure mode is eliminated structurally, not
//      by fixing one particular value.
//   3. The actual-vs-predicted table loop now measures the true element
//      count of y_test_plot and y_pred_plot independently (via size(v,'*'),
//      which is correct regardless of row- vs column-vector orientation,
//      unlike the previous size(v,1)) and, if they ever differ, pads the
//      shorter series with blank cells rather than truncating -- every row
//      of the CSV ends up with exactly the same number of columns, and the
//      full length of whichever series is longer is still written out in
//      full (no column or data ever silently dropped).
// ---------------------------------------------------------------------------

function s = safe_str(v)
    // Guarantees a 1x1 string out of literally anything passed in.
    if type(v) == 10 & size(v, '*') <= 1 then
        // Already a plain scalar (or empty) string -- the common case.
        if size(v, '*') == 0 then
            s = "";
        else
            s = v;
        end
    elseif size(v, '*') == 0 then
        s = "n/a";
    elseif size(v, '*') == 1 then
        s = string(v);
    else
        // Unexpectedly more than one element: join them rather than pick
        // one (or crash) -- keeps every bit of the underlying data visible
        // in the exported file, just packed into a single field.
        parts = string(v);
        s = parts(1);
        for k = 2:size(parts, '*')
            s = s + "; " + parts(k);
        end
    end
endfunction

function acc = append_line(acc, piece)
    // Appends exactly one guaranteed-scalar line onto a growing Nx1 column
    // of strings. Because `piece` is coerced to 1x1 by safe_str() first,
    // this vertical concatenation can never hit "inconsistent row/column
    // dimensions", regardless of what shape `piece` would otherwise have been.
    line1 = safe_str(piece);
    if size(acc, '*') == 0 then
        acc = line1;
    else
        acc = [acc; line1];
    end
endfunction

function export_results_txt(path)
    global gui app_state
    // get(gui.results_text, "string") may come back as either a scalar
    // string or a string matrix depending on the Scilab runtime. Previously
    // this was folded directly into one big vertical concatenation, which
    // broke ("inconsistent row/column dimensions") if it came back in a
    // shape the rest of the concatenation didn't expect. Each existing
    // results-panel line is now re-appended individually via append_line(),
    // so whatever shape get() returns, every line lands safely.
    raw_lines = get(gui.results_text, "string");
    lines = [];
    for k = 1:size(raw_lines, '*')
        lines = append_line(lines, raw_lines(k));
    end

    if typeof(app_state.last_backtest) <> "constant" then
        bt = app_state.last_backtest;
        sharpe_str = "n/a"; if ~isnan(bt.sharpe_ratio) then sharpe_str = safe_str(bt.sharpe_ratio); end
        winrate_str = "n/a"; if ~isnan(bt.win_rate_pct) then winrate_str = safe_str(bt.win_rate_pct) + "%"; end
        lines = append_line(lines, " ");
        lines = append_line(lines, "--- Last Backtest ---");
        lines = append_line(lines, "Starting capital: " + safe_str(bt.starting_capital));
        lines = append_line(lines, "Trades made: " + safe_str(bt.n_trades) + " (" + ..
            safe_str(bt.n_completed_trades) + " completed round-trip(s))");
        lines = append_line(lines, "Transaction cost: " + safe_str(bt.transaction_cost_pct) + ..
            "%   Slippage: " + safe_str(bt.slippage_pct) + "%");
        lines = append_line(lines, "Strategy final: " + safe_str(bt.strategy_final) + " (" + ..
            safe_str(bt.strategy_return_pct) + "%)");
        lines = append_line(lines, "Buy & Hold final: " + safe_str(bt.buyhold_final) + " (" + ..
            safe_str(bt.buyhold_return_pct) + "%)");
        lines = append_line(lines, "Max drawdown: " + safe_str(bt.max_drawdown_pct) + "%");
        lines = append_line(lines, "Annualized volatility: " + safe_str(bt.volatility_pct_annualized) + "%");
        lines = append_line(lines, "Sharpe ratio: " + sharpe_str);
        lines = append_line(lines, "Win rate: " + winrate_str);
    end
    fd = mopen(path, "w");
    mputl(lines, fd);
    mclose(fd);
endfunction

function export_results_csv(path)
    // A metrics block, then the full actual-vs-predicted test-set series --
    // opens cleanly in Excel/Sheets/pandas. Built line-by-line via
    // append_line()/safe_str() (see the comment above export_results_txt)
    // so a single unexpectedly-shaped value can never break the whole export.
    global app_state
    lr = app_state.last_results;
    lp = app_state.last_plot;

    accuracy_str = "n/a"; if ~isnan(lr.accuracy_pct) then accuracy_str = safe_str(lr.accuracy_pct); end

    lines = [];
    lines = append_line(lines, "Metric,Value");
    lines = append_line(lines, "Dataset," + safe_str(lr.dataset_label));
    lines = append_line(lines, "Model," + safe_str(lr.model_name));
    lines = append_line(lines, "Rows_Used," + safe_str(lr.rows_used));
    lines = append_line(lines, "Train_Pct," + safe_str(round(lr.split_ratio*100)));
    lines = append_line(lines, "Test_Pct," + safe_str(round((1-lr.split_ratio)*100)));
    lines = append_line(lines, "RMSE," + safe_str(lr.rmse));
    lines = append_line(lines, "MAE," + safe_str(lr.mae));
    lines = append_line(lines, "MAPE_pct," + safe_str(lr.mape));
    lines = append_line(lines, "R2," + safe_str(lr.r2));
    lines = append_line(lines, "Prediction_Accuracy_pct," + accuracy_str);
    lines = append_line(lines, "Current_Price," + safe_str(lr.current_price));
    lines = append_line(lines, "Predicted_Next_Price," + safe_str(lr.next_price));
    lines = append_line(lines, "Rough_Uncertainty_Band_Low_NOT_a_true_prediction_interval," + safe_str(lr.ci_lo));
    lines = append_line(lines, "Rough_Uncertainty_Band_High_NOT_a_true_prediction_interval," + safe_str(lr.ci_hi));
    lines = append_line(lines, "Predicted_Change_pct," + safe_str(lr.pct_change));
    lines = append_line(lines, "Signal," + safe_str(lr.signal_action));
    lines = append_line(lines, "Buy_Threshold_pct," + safe_str(lr.buy_threshold));
    lines = append_line(lines, "Sell_Threshold_pct," + safe_str(lr.sell_threshold));

    if typeof(app_state.last_backtest) <> "constant" then
        bt = app_state.last_backtest;
        sharpe_str = "n/a"; if ~isnan(bt.sharpe_ratio) then sharpe_str = safe_str(bt.sharpe_ratio); end
        winrate_str = "n/a"; if ~isnan(bt.win_rate_pct) then winrate_str = safe_str(bt.win_rate_pct); end
        lines = append_line(lines, "Backtest_Starting_Capital," + safe_str(bt.starting_capital));
        lines = append_line(lines, "Backtest_Trades_Made," + safe_str(bt.n_trades));
        lines = append_line(lines, "Backtest_Completed_RoundTrips," + safe_str(bt.n_completed_trades));
        lines = append_line(lines, "Backtest_Transaction_Cost_pct," + safe_str(bt.transaction_cost_pct));
        lines = append_line(lines, "Backtest_Slippage_pct," + safe_str(bt.slippage_pct));
        lines = append_line(lines, "Backtest_Strategy_Final," + safe_str(bt.strategy_final));
        lines = append_line(lines, "Backtest_Strategy_Return_pct," + safe_str(bt.strategy_return_pct));
        lines = append_line(lines, "Backtest_BuyHold_Final," + safe_str(bt.buyhold_final));
        lines = append_line(lines, "Backtest_BuyHold_Return_pct," + safe_str(bt.buyhold_return_pct));
        lines = append_line(lines, "Backtest_Max_Drawdown_pct," + safe_str(bt.max_drawdown_pct));
        lines = append_line(lines, "Backtest_Annualized_Volatility_pct," + safe_str(bt.volatility_pct_annualized));
        lines = append_line(lines, "Backtest_Sharpe_Ratio," + sharpe_str);
        lines = append_line(lines, "Backtest_Win_Rate_pct," + winrate_str);
    end

    lines = append_line(lines, "");
    lines = append_line(lines, "Index,Actual,Predicted");

    // size(v,'*') is the true element count regardless of whether v happens
    // to be a column vector, a row vector, or a bare scalar -- unlike
    // size(v,1), which silently returns 1 for a row vector and would have
    // quietly produced a 1-row table instead of the intended n-row one.
    // Genuinely shouldn't happen (both come from the same fitted model's
    // test period), but if actual/predicted ever came back different
    // lengths, every row below still gets written with exactly the same
    // 3 columns and nothing is truncated -- the shorter series is padded
    // with blank cells, not cut short. (No extra note row is inserted here:
    // that would itself be a row with a different column count than its
    // neighbors, which is exactly the inconsistency this fix exists to
    // prevent -- a mismatch, if it ever happens, is visible instead as
    // blank Actual/Predicted cells in the data below.)
    n_actual = size(lp.y_test_plot, '*');
    n_pred = size(lp.y_pred_plot, '*');
    n = max(n_actual, n_pred);
    for i = 1:n
        if i <= n_actual then actual_cell = safe_str(lp.y_test_plot(i)); else actual_cell = ""; end
        if i <= n_pred then pred_cell = safe_str(lp.y_pred_plot(i)); else pred_cell = ""; end
        lines = append_line(lines, string(i) + "," + actual_cell + "," + pred_cell);
    end

    fd = mopen(path, "w");
    mputl(lines, fd);
    mclose(fd);
endfunction

function export_results_pdf(path)
    // Exports the currently-displayed chart (redrawn fresh first, so it
    // reflects the current moving-average checkbox state) as a PDF.
    // drawnow() forces any pending render to flush before the export reads
    // the window -- redraw_chart()'s plot/clf calls can otherwise still be
    // queued rather than actually painted yet.
    global CHART_FIGURE_ID
    redraw_chart();
    drawnow();
    xs2pdf(CHART_FIGURE_ID, path);
endfunction

// ---------------------------------------------------------------------------
// Callback: "Export Results" button. The save dialog offers CSV, PDF, and
// TXT; whichever extension the user actually types/picks decides the
// format (defaulting to TXT if the extension isn't recognized).
// ---------------------------------------------------------------------------
function on_export_results()
    global gui app_state

    if typeof(app_state.model) == "constant" then
        set(gui.status_text, "string", "Run an analysis first -- nothing to export yet.");
        return
    end

    path = uiputfile(["*.csv"; "*.pdf"; "*.txt"], pwd(), ..
        "Export results as CSV (data table), PDF (chart), or TXT (summary)...");
    if path == "" then
        return   // user cancelled
    end

    [dummy_path, dummy_name, ext] = fileparts(path);
    ext = convstr(ext, "l");

    try
        if ext == ".csv" then
            export_results_csv(path);
        elseif ext == ".pdf" then
            export_results_pdf(path);
        elseif ext == ".txt" then
            export_results_txt(path);
        else
            // No recognized extension (e.g. the user typed a bare filename
            // with none at all) -- default to TXT, and make sure the saved
            // file actually carries that extension rather than ending up
            // ambiguous/extension-less.
            path = path + ".txt";
            export_results_txt(path);
        end
    catch
        messagebox(lasterror(), "Export failed", "error");
        return
    end
    set(gui.status_text, "string", "Results exported to " + path);
endfunction


// ---------------------------------------------------------------------------
// Menu callback: File > Load Custom CSV...
// Expects the same column layout as the bundled samples: Date, Open, High,
// Low, Close, Volume (this is exactly what the Python project's
// export_for_scilab.py / fetch_data.py bridge scripts produce). Validated
// the same way the bundled samples are, by load_dataset() itself.
// ---------------------------------------------------------------------------
function on_load_custom_csv()
    global gui app_state
    path = uigetfile(["*.csv"], "", "Select a CSV (Date,Open,High,Low,Close,Volume)");
    if path == "" then
        return   // user cancelled
    end

    try
        d = load_dataset(path);
    catch
        messagebox(lasterror(), "Could not load CSV", "error");
        return
    end

    app_state.custom_csv_path = path;
    n_items = size(app_state.dataset_labels, 2);
    set(gui.dataset_popup, "string", strcat(app_state.dataset_labels, "|") + "|Custom: " + path);
    set(gui.dataset_popup, "value", n_items + 1);
    app_state.data = d;
    invalidate_model();
    msg = "Loaded custom file: " + string(d.n) + " rows.";
    if size(d.warnings, 1) > 0 then
        msg = msg + " Note: " + strcat(d.warnings, " ");
    end
    set(gui.status_text, "string", msg);
endfunction


function on_about()
    messagebox([
        "Stock Market Analysis & Prediction Studio"; " "; ..
        "An interactive Scilab GUI for exploring Linear Regression and"; ..
        "AR time-series forecasting on stock price data."; " "; ..
        "All modeling logic lives in model_engine.sce and is covered by"; ..
        "a headless test suite (test_model_engine.sce)."; " "; ..
        "The bundled datasets are SYNTHETIC demo data, not real historical"; ..
        "prices, and this app has no live market-data connection -- it"; ..
        "only ever reads bundled or user-supplied CSV files."; " "; ..
        "Educational tool -- not financial advice." ..
    ], "About", "info");
endfunction


// ---------------------------------------------------------------------------
// Build the window
// ---------------------------------------------------------------------------
gui.fig = figure("figure_name", "Stock Market Analysis & Prediction Studio", ..
                  "position", [50, 50, 1050, 900]);

// --- menu bar ---
m_file = uimenu(gui.fig, "label", "File");
uimenu(m_file, "label", "Load Custom CSV...", "callback", "on_load_custom_csv()");
uimenu(m_file, "label", "Exit", "callback", "close(gui.fig)");
m_help = uimenu(gui.fig, "label", "Help");
uimenu(m_help, "label", "About", "callback", "on_about()");

// Every uicontrol below uses "units","normalized" with its position given as
// a fraction (0-1) of the figure's width/height, computed once from the
// original 1050x900 design (e.g. x_frac = x_px/1050). This is a deliberate
// change from fixed pixel positions: Scilab recomputes normalized positions
// itself, from its own internal rendering size, every time the figure is
// resized/maximized/restored -- so the layout can never depend on a script
// reading the figure's current size correctly. (An earlier version of this
// fix used a resizefcn callback that read gui.fig.figure_size and shifted
// pixel positions manually; that measurably overshot in live testing on
// Windows -- Data Selection and the Model label were pushed off the top
// entirely on maximize, worse than the original bug -- so it's been
// replaced with this approach rather than patched further.)

// --- panel 1: data + model + split + MA (top-left) ---
gui.frame_data_selection = uicontrol(gui.fig, "style", "frame", "units", "normalized", ..
    "position", [0.009524, 0.688889, 0.247619, 0.300000]);
gui.label_data_selection = uicontrol(gui.fig, "style", "text", "string", "1. Data Selection", "fontweight", "bold", ..
    "units", "normalized", "position", [0.019048, 0.950000, 0.190476, 0.022222], "horizontalalignment", "left");
gui.dataset_popup = uicontrol(gui.fig, "style", "popupmenu", ..
    "string", strcat(app_state.dataset_labels, "|"), ..
    "units", "normalized", "position", [0.019048, 0.913333, 0.228571, 0.027778], "callback", "on_dataset_changed()");

gui.label_model = uicontrol(gui.fig, "style", "text", "string", "2. Model", "fontweight", "bold", ..
    "units", "normalized", "position", [0.019048, 0.875556, 0.190476, 0.022222], "horizontalalignment", "left");
// A single 3-item popupmenu instead of one radiobutton per model -- see the
// comment above on_model_changed() for why. Also frees up the vertical
// space the second radiobutton used to occupy (left as breathing room
// below rather than repacking every position beneath it).
gui.model_popup = uicontrol(gui.fig, "style", "popupmenu", ..
    "string", "Linear Regression|AR Time-Series (autoregressive)|Exponential Smoothing (Holt)", ..
    "units", "normalized", "position", [0.019048, 0.844444, 0.228571, 0.027778], "callback", "on_model_changed()");

gui.label_split = uicontrol(gui.fig, "style", "text", "string", "3. Train/Test Split", "fontweight", "bold", ..
    "units", "normalized", "position", [0.019048, 0.777778, 0.190476, 0.022222], "horizontalalignment", "left");
gui.split_slider = uicontrol(gui.fig, "style", "slider", "min", 0.5, "max", 0.95, "value", 0.8, ..
    "units", "normalized", "position", [0.019048, 0.753333, 0.228571, 0.022222], "callback", "on_slider_moved()");
gui.split_label = uicontrol(gui.fig, "style", "text", "string", "Train/Test split: 80% / 20%", ..
    "units", "normalized", "position", [0.019048, 0.727778, 0.228571, 0.020000], "horizontalalignment", "left");

gui.cb_moving_avg = uicontrol(gui.fig, "style", "checkbox", "string", "Show 20-day moving average", ..
    "value", 0, "units", "normalized", "position", [0.019048, 0.700000, 0.228571, 0.022222], "callback", "on_ma_toggle()");

// --- panel 2: thresholds, AR lookback, and backtest costs ---
gui.frame_thresholds = uicontrol(gui.fig, "style", "frame", "units", "normalized", ..
    "position", [0.009524, 0.466667, 0.247619, 0.211111]);
gui.label_thresholds = uicontrol(gui.fig, "style", "text", "string", "4. Thresholds & Costs", "fontweight", "bold", ..
    "units", "normalized", "position", [0.019048, 0.650000, 0.209524, 0.022222], "horizontalalignment", "left");

gui.label_buy = uicontrol(gui.fig, "style", "text", "string", "Buy signal at (%):", ..
    "units", "normalized", "position", [0.019048, 0.616667, 0.142857, 0.022222], "horizontalalignment", "left");
gui.buy_threshold_edit = uicontrol(gui.fig, "style", "edit", "string", "0.5", ..
    "units", "normalized", "position", [0.171429, 0.616667, 0.066667, 0.024444]);

gui.label_sell = uicontrol(gui.fig, "style", "text", "string", "Sell signal at (%):", ..
    "units", "normalized", "position", [0.019048, 0.583333, 0.142857, 0.022222], "horizontalalignment", "left");
gui.sell_threshold_edit = uicontrol(gui.fig, "style", "edit", "string", "-0.5", ..
    "units", "normalized", "position", [0.171429, 0.583333, 0.066667, 0.024444]);

gui.label_ar_lookback = uicontrol(gui.fig, "style", "text", "string", "AR lookback (days):", ..
    "units", "normalized", "position", [0.019048, 0.550000, 0.142857, 0.022222], "horizontalalignment", "left");
gui.ar_lookback_edit = uicontrol(gui.fig, "style", "edit", "string", "10", ..
    "units", "normalized", "position", [0.171429, 0.550000, 0.066667, 0.024444]);

gui.label_txn = uicontrol(gui.fig, "style", "text", "string", "Txn cost / trade (%):", ..
    "units", "normalized", "position", [0.019048, 0.516667, 0.142857, 0.022222], "horizontalalignment", "left");
gui.txn_cost_edit = uicontrol(gui.fig, "style", "edit", "string", "0", ..
    "units", "normalized", "position", [0.171429, 0.516667, 0.066667, 0.024444]);

gui.label_slippage = uicontrol(gui.fig, "style", "text", "string", "Slippage (%):", ..
    "units", "normalized", "position", [0.019048, 0.483333, 0.142857, 0.022222], "horizontalalignment", "left");
gui.slippage_edit = uicontrol(gui.fig, "style", "edit", "string", "0", ..
    "units", "normalized", "position", [0.171429, 0.483333, 0.066667, 0.024444]);

// --- panel 3: actions, 3x2 grid ---
gui.frame_actions = uicontrol(gui.fig, "style", "frame", "units", "normalized", ..
    "position", [0.009524, 0.288889, 0.247619, 0.166667]);
gui.btn_run_analysis = uicontrol(gui.fig, "style", "pushbutton", "string", "Run Analysis", "fontweight", "bold", ..
    "units", "normalized", "position", [0.019048, 0.400000, 0.104762, 0.033333], "callback", "on_run_analysis()");
gui.btn_run_backtest = uicontrol(gui.fig, "style", "pushbutton", "string", "Run Backtest", "fontweight", "bold", ..
    "units", "normalized", "position", [0.133333, 0.400000, 0.104762, 0.033333], "callback", "on_run_backtest()");
gui.btn_model_info = uicontrol(gui.fig, "style", "pushbutton", "string", "Model Info", ..
    "units", "normalized", "position", [0.019048, 0.355556, 0.104762, 0.033333], "callback", "on_model_info()");
gui.btn_reset = uicontrol(gui.fig, "style", "pushbutton", "string", "Reset", ..
    "units", "normalized", "position", [0.133333, 0.355556, 0.104762, 0.033333], "callback", "on_reset()");
gui.btn_compare = uicontrol(gui.fig, "style", "pushbutton", "string", "Compare", ..
    "units", "normalized", "position", [0.019048, 0.311111, 0.104762, 0.033333], "callback", "on_compare_models()");
gui.btn_export = uicontrol(gui.fig, "style", "pushbutton", "string", "Export", ..
    "units", "normalized", "position", [0.133333, 0.311111, 0.104762, 0.033333], "callback", "on_export_results()");

gui.status_text = uicontrol(gui.fig, "style", "text", "string", "Pick a dataset to begin.", ..
    "units", "normalized", "position", [0.009524, 0.250000, 0.247619, 0.027778], "horizontalalignment", "left");

// --- panel 4: results (bottom-left) ---
gui.frame_results = uicontrol(gui.fig, "style", "frame", "units", "normalized", ..
    "position", [0.009524, 0.011111, 0.247619, 0.227778]);
gui.label_results = uicontrol(gui.fig, "style", "text", "string", "Results", "fontweight", "bold", ..
    "units", "normalized", "position", [0.019048, 0.213333, 0.104762, 0.020000], "horizontalalignment", "left");
// Colored BUY/SELL/HOLD indicator, sharing the same row as "Results" but
// right-aligned in the remaining panel width -- see on_run_analysis().
gui.label_signal_indicator = uicontrol(gui.fig, "style", "text", "string", "", "fontweight", "bold", ..
    "units", "normalized", "position", [0.133333, 0.213333, 0.114286, 0.020000], "horizontalalignment", "right");
gui.results_text = uicontrol(gui.fig, "style", "listbox", ..
    "string", "Run an analysis to see results here.", ..
    "units", "normalized", "position", [0.019048, 0.022222, 0.228571, 0.183333]);

// --- chart placeholder (right side) -- charts open in their OWN dedicated
// windows (CHART_FIGURE_ID / BACKTEST_FIGURE_ID), deliberately never drawn
// into this main window: clf()-ing a figure that also holds every button,
// slider, and panel would wipe the whole GUI out along with the chart. ---
gui.frame_chart_placeholder = uicontrol(gui.fig, "style", "frame", "units", "normalized", ..
    "position", [0.271429, 0.011111, 0.719048, 0.977778]);
// NOTE: uicontrol's "string" property for style="text" requires a single
// (scalar) string -- passing a multi-row/multi-element matrix here throws
// "Wrong size for 'String' property: string expected." at runtime. Build one
// scalar string with embedded newlines instead (ascii(10) = LF), the same
// "+" string-concatenation already used throughout model_engine.sce's own
// error messages. (messagebox() elsewhere in this file is a different API
// that does accept a matrix for multi-line messages -- not affected.)
chart_placeholder_msg = "Charts open in separate windows." + ascii(10) + ascii(10) + ..
    "Click Run Analysis to open the actual-vs-predicted chart." + ascii(10) + ..
    "Click Run Backtest to open the strategy-vs-buy&hold chart." + ascii(10) + ascii(10) + ..
    "This window stays open and interactive the whole time --" + ascii(10) + ..
    "closing a chart window never closes this one.";
gui.label_chart_placeholder = uicontrol(gui.fig, "style", "text", ..
    "string", chart_placeholder_msg, ..
    "units", "normalized", "position", [0.319048, 0.444444, 0.623810, 0.111111], "horizontalalignment", "center", ..
    "fontsize", 3, "foregroundcolor", [0.5 0.5 0.5]);

// Load the first dataset by default so the window isn't empty on first run.
on_dataset_changed();

disp("GUI built. Interact with the window that just opened.");
