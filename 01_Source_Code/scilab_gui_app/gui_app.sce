// ============================================================================
// gui_app.sce -- StockVision: unified stock analysis & prediction dashboard.
//
// One Scilab figure holds everything: controls, three embedded charts
// (price/forecast, model comparison, backtest equity) and the text panels
// (data quality, results, comparison, walk-forward, backtest, assumptions).
// Nothing opens in a separate window.
//
// Run from this folder:  exec("gui_app.sce", -1);
// All modelling lives in model_engine.sce; this file only builds widgets,
// holds state and renders results. The figure is never cleared with
// clf()/scf()/xdel(): charts are refreshed by deleting the children of their
// own axes only, so the controls always survive.
// ============================================================================

clear; clc;

// Resolve the app folder so the script works from any working directory.
APP_DIR = "";
try
    APP_DIR = get_absolute_file_path("gui_app.sce");
catch
    APP_DIR = pwd() + filesep();
end
global APP_DIR;
exec(APP_DIR + "model_engine.sce", -1);

global gui app_state gui_quiet ES_ALPHA ES_BETA GUI_BG GUI_HEAD;
if ~exists("gui_quiet") | isempty(gui_quiet) then gui_quiet = %f; end   // %t: print instead of dialogs
ES_ALPHA = 0.3; ES_BETA = 0.1;                                          // fixed Holt parameters

gui = struct();
app_state = struct();
app_state.dataset_files = [APP_DIR + "sample_data/tech_growth_stock.csv", ..
                           APP_DIR + "sample_data/blue_chip_stock.csv", ..
                           APP_DIR + "sample_data/volatile_stock.csv"];
app_state.dataset_labels = ["Tech Growth Stock (synthetic)", "Blue Chip Stock (synthetic)", ..
                            "Volatile Stock (synthetic)"];
app_state.dataset_idx = 1;
app_state.custom_path = "";
app_state.data = [];
app_state.dq = [];
app_state.model_type = "LR";
app_state.split_ratio = 0.8;
app_state.ar_lookback = 10;
app_state.n_folds = 5;
app_state.analysis = [];     // run_model result for the selected model
app_state.naive = [];        // naive baseline on the same window
app_state.signal = [];
app_state.cmp = [];          // compare_models result (all models + walk-forward)
app_state.bt = [];           // run_backtest result for the analysed model
app_state.show_ma = %t;
app_state.info_tab = "dq";   // top-right panel: "dq" or "asm"
app_state.info_dq = ""; app_state.info_asm = "";

// Palette
GUI_BG = [0.93 0.94 0.95];
GUI_HEAD = [0.13 0.25 0.42];
GUI_WHITE = [1 1 1];


// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------
function r = has(x)
    r = (typeof(x) == "st");
endfunction


function set_status(msg, level)
    // level: "info" (grey), "ok" (green), "error" (red).
    global gui
    if argn(2) < 2 then level = "info"; end
    select level
    case "ok" then col = [0.05 0.45 0.15];
    case "error" then col = [0.75 0.1 0.1];
    else col = [0.15 0.15 0.15];
    end
    set(gui.status, "foregroundcolor", col);
    set(gui.status, "string", " " + msg);
    drawnow();
endfunction


function show_dialog(title, msg, kind)
    // Popups only for real problems; in quiet mode (scripted runs) print.
    global gui_quiet
    if gui_quiet then
        mprintf("[%s] %s\n", title, strcat(msg, " / "));
    else
        messagebox(msg, title, kind);
    end
endfunction


function out = html_escape(s)
    out = strsubst(s, "&", "&amp;");
    out = strsubst(out, "<", "&lt;");
    out = strsubst(out, ">", "&gt;");
endfunction


function out = to_html_lines(lines)
    // Listbox rows as HTML: keeps spacing (&nbsp;), bolds best-value cells
    // (tokens ending in '*') in green, and colours signal / baseline lines.
    out = repmat("", size(lines, 1), 1);
    for k = 1:size(lines, 1)
        s = html_escape(lines(k));
        body = ""; i = 1; n = length(s);
        while i <= n
            c = part(s, i);
            if c == " " then
                body = body + "&nbsp;"; i = i + 1;
            else
                j = i;
                while j <= n & part(s, j) <> " "
                    j = j + 1;
                end
                tok = part(s, i:j-1);
                if length(tok) > 1 & part(tok, length(tok)) == "*" & or(part(tok, 1) == ["0","1","2","3","4","5","6","7","8","9","-","+","."]) then
                    tok = "<span style=''color:#0a7d2e;font-weight:bold''>" + tok + "</span>";
                end
                body = body + tok; i = j;
            end
        end
        col = "";
        raw = lines(k);
        if part(raw, 1:7) == "Signal:" then
            if strindex(raw, "BUY") <> [] then col = "#0a7d2e";
            elseif strindex(raw, "SELL") <> [] then col = "#b01818";
            else col = "#8a6d00"; end
        elseif strindex(raw, "does NOT beat") <> [] | strindex(raw, "No StockVision model") <> [] then
            col = "#b01818";
        elseif part(raw, 1:12) == "Model status" then
            col = "#0a7d2e";
        end
        if col <> "" then
            body = "<span style=''color:" + col + ";font-weight:bold''>" + body + "</span>";
        end
        out(k) = "<html>" + body + "</html>";
    end
endfunction


function set_list(h, lines)
    set(h, "string", to_html_lines(lines));
    set(h, "value", []);
endfunction


function [ok, p, msg] = read_params()
    // Validates every edit box. On failure ok=%f and msg says which field.
    global gui
    p = struct(); msg = ""; ok = %f;
    names = ["Buy threshold", "Sell threshold", "Starting capital", "Transaction cost", "Slippage"];
    hs = list(gui.ed_buy, gui.ed_sell, gui.ed_capital, gui.ed_cost, gui.ed_slip);
    v = zeros(1, 5);
    for k = 1:5
        s = stripblanks(get(hs(k), "string"));
        if ~is_valid_number_string(s) then
            msg = names(k) + " must be a plain number (got [" + s + "])."; return
        end
        v(k) = strtod(s);
    end
    if v(1) <= v(2) then msg = "Buy threshold must be greater than the sell threshold."; return; end
    if v(3) <= 0 then msg = "Starting capital must be positive."; return; end
    if v(4) < 0 | v(4) > 10 | v(5) < 0 | v(5) > 10 then
        msg = "Transaction cost and slippage must be between 0 and 10 (percent)."; return
    end
    p.buy = v(1); p.sell = v(2); p.capital = v(3); p.cost = v(4); p.slip = v(5);
    ok = %t;
endfunction


function [ok, lb, nf, msg] = read_model_params()
    global gui
    ok = %f; lb = 10; nf = 5; msg = "";
    s1 = stripblanks(get(gui.ed_lookback, "string"));
    s2 = stripblanks(get(gui.ed_folds, "string"));
    if ~is_valid_number_string(s1) | strtod(s1) <> round(strtod(s1)) | strtod(s1) < 2 | strtod(s1) > 60 then
        msg = "AR lookback must be a whole number from 2 to 60."; return
    end
    if ~is_valid_number_string(s2) | strtod(s2) <> round(strtod(s2)) | strtod(s2) < 1 | strtod(s2) > 10 then
        msg = "Walk-forward folds must be a whole number from 1 to 10."; return
    end
    lb = strtod(s1); nf = strtod(s2); ok = %t;
endfunction


function set_button_states()
    // Disable actions whose prerequisites are missing.
    global gui app_state
    have_data = has(app_state.data);
    have_an = has(app_state.analysis);
    set(gui.btn_run, "enable", tf_str(have_data));
    set(gui.btn_compare, "enable", tf_str(have_data));
    set(gui.btn_wf, "enable", tf_str(have_data));
    set(gui.btn_backtest, "enable", tf_str(have_an));
    set(gui.btn_export, "enable", tf_str(have_an));
endfunction


function s = tf_str(b)
    if b then s = "on"; else s = "off"; end
endfunction


function nm = model_display_name(key)
    global app_state ES_ALPHA ES_BETA
    select key
    case "LR" then nm = "Linear Regression";
    case "AR" then nm = "AR(" + string(app_state.ar_lookback) + ")";
    case "ES" then nm = "Exp. Smoothing";
    else nm = key;
    end
endfunction


// ---------------------------------------------------------------------------
// Chart drawing (embedded axes; only each axes' own children are deleted)
// ---------------------------------------------------------------------------
function ax = make_axes(x, y, w, h)
    // Axes occupying the normalized panel (x, y, w, h), origin bottom-left.
    // axes_bounds uses a top-left origin, hence 1 - (y + h).
    global gui
    ax = newaxes(gui.fig);
    ax.axes_bounds = [x, 1 - (y + h), w, h];
    ax.margins = [0.10, 0.03, 0.04, 0.17];
    ax.background = color(255, 255, 255);
    ax.box = "on";
    ax.font_size = 2;
    ax.grid = [color(225, 225, 225), color(225, 225, 225)];
endfunction


function clear_axes(ax, ph, msg)
    // Empty state: hide the axes and show a native placeholder (frame + text),
    // which paints reliably before any plot exists.
    sca(ax);
    delete(ax.children);
    ax.visible = "off";
    set(ph(1), "visible", "on"); set(ph(2), "string", msg); set(ph(2), "visible", "on");
endfunction


function restore_axes(ax, ph)
    // Plot mode: hide the placeholder, clear old content, restore margins.
    set(ph(1), "visible", "off"); set(ph(2), "visible", "off");
    sca(ax); delete(ax.children);
    ax.visible = "on";
    ax.margins = [0.10, 0.03, 0.04, 0.17]; ax.box = "on";
    ax.axes_visible = ["on", "on", "on"];
endfunction


function style_last(col, thick, lstyle)
    // Colour/width/style of the polyline created by the last plot() call.
    e = gce();
    p = e.children(1);
    p.foreground = color(col(1), col(2), col(3));
    p.thickness = thick;
    p.line_style = lstyle;
endfunction


function set_date_ticks(ax, dates, x_lo, x_hi)
    // ~6 evenly spaced date labels (yy-mm-dd) along the x axis.
    idx = unique(round(linspace(x_lo, x_hi, 6)));
    idx = idx(idx >= 1 & idx <= size(dates, 1));
    labs = part(dates(idx), 3:10);
    ax.x_ticks = tlist(["ticks", "locations", "labels"], idx(:), labs(:));
endfunction


function t = key_span(col, txt)
    t = "<b style=''color:" + col + "''>" + txt + "</b>";
endfunction


function s = main_key_html(show_ma)
    // Colour key matching the plotted lines (HTML label above the chart).
    s = "<html>&nbsp;" + key_span("#8290a8", "&#9472; Training close") + "&nbsp;&nbsp; " + key_span("#000000", "&#9472; Actual (test)") + ..
        "&nbsp;&nbsp; " + key_span("#d22828", "- - Predicted");
    if show_ma then s = s + "&nbsp;&nbsp; " + key_span("#2850dc", "-.- 20-day MA"); end
    s = s + "&nbsp;&nbsp; " + key_span("#e08a00", "&#9670; Next-day forecast") + "&nbsp;&nbsp; " + key_span("#555555", "&#124; train/test split") + "</html>";
endfunction


function draw_main_chart()
    // Test window (actual vs predicted, 20-day MA) with equal-length training
    // context, the train/test divider and the next-day forecast.
    global gui app_state
    ax = gui.ax_main;
    if ~has(app_state.analysis) then
        clear_axes(ax, gui.ph_main, "No analysis yet - click Run Analysis");
        set(gui.key_main, "string", "");
        set(gui.head_main, "string", " PRICE & PREDICTION");
        return
    end
    r = app_state.analysis; d = app_state.data; n = d.n;
    restore_axes(ax, gui.ph_main);
    vis_lo = max(1, r.split_cal - r.n_test + 1);
    hist_x = (vis_lo:r.split_cal)'; hist_y = d.close(vis_lo:r.split_cal);
    vis_vals = [hist_y; r.y_true; r.y_pred; r.next_price];
    pad = 0.08 * (max(vis_vals) - min(vis_vals) + 1e-9);
    ylo = min(vis_vals) - pad; yhi = max(vis_vals) + pad;
    labels = [];   // legend labels in creation order

    plot(hist_x, hist_y); style_last([130 140 160], 2, 1);
    labels = [labels, "Train"];
    plot([r.split_cal + 0.5, r.split_cal + 0.5], [ylo, yhi]); style_last([90 90 90], 1, 3);
    labels = [labels, "Split"];
    plot(r.test_idx, r.y_true); style_last([0 0 0], 2, 1);
    labels = [labels, "Actual"];
    plot(r.test_idx, r.y_pred); style_last([210 40 40], 2, 2);
    labels = [labels, "Predicted"];
    if app_state.show_ma then
        ma = moving_average(r.y_true, 20, r.ma_history);
        plot(r.test_idx, ma); style_last([40 80 220], 2, 4);
        labels = [labels, "20d MA"];
    end
    plot(n + 1, r.next_price, "d");
    e = gce(); e.children(1).mark_background = color(255, 170, 0);
    e.children(1).mark_foreground = color(120, 60, 0); e.children(1).mark_size = 8;
    labels = [labels, "Next day"];

    ax.data_bounds = [vis_lo, ylo; n + 4, yhi];
    ax.tight_limits = "on";
    set_date_ticks(ax, d.dates, vis_lo, n);
    ax.margins = [0.08, 0.03, 0.04, 0.17];
    ax.title.text = r.name + ": actual vs predicted (test window + equal training context)";
    ax.title.font_size = 3;
    ax.y_label.text = "Price"; ax.x_label.text = "Date (yy-mm-dd)";
    set(gui.key_main, "string", main_key_html(app_state.show_ma));
    set(gui.head_main, "string", " PRICE & PREDICTION -- " + r.name);
endfunction


function draw_comparison_chart()
    // Grouped bars: single-split test RMSE and walk-forward mean RMSE.
    global gui app_state
    ax = gui.ax_cmp;
    if ~has(app_state.cmp) then
        clear_axes(ax, gui.ph_cmp, "No comparison yet - click Compare Models");
        return
    end
    M = app_state.cmp.M; lab = app_state.cmp.labels;
    restore_axes(ax, gui.ph_cmp);
    vals = [M(:, 1), M(:, 6)];
    bar(1:4, vals, 0.7, "grouped");
    e = gce();
    e.children(2).background = color(60, 120, 200);    // first series: test window
    e.children(1).background = color(240, 150, 40);    // second series: walk-forward
    ymax = max(vals) * 1.25;
    ax.data_bounds = [0.4, 0; 4.6, ymax];
    ax.tight_limits = "on";
    ax.x_ticks = tlist(["ticks", "locations", "labels"], (1:4)', lab(:));
    for i = 1:4
        xstring(i - 0.33, vals(i, 1) + ymax * 0.015, msprintf("%.2f", vals(i, 1)));
        t = gce(); t.font_size = 1;
        xstring(i + 0.03, vals(i, 2) + ymax * 0.015, msprintf("%.2f", vals(i, 2)));
        t = gce(); t.font_size = 1;
    end
    ax.margins = [0.12, 0.06, 0.04, 0.17];
    ax.title.text = "RMSE by model (lower is better)"; ax.title.font_size = 3;
    lg = legend(["Test window", "Walk-forward mean"], "in_upper_left"); lg.font_size = 2;
    ax.y_label.text = "RMSE"; ax.x_label.text = "";
endfunction


function draw_equity_chart()
    // Strategy vs buy & hold equity with BUY / SELL execution markers.
    global gui app_state
    ax = gui.ax_eq;
    if ~has(app_state.bt) then
        clear_axes(ax, gui.ph_eq, "No backtest yet - click Run Backtest");
        return
    end
    bt = app_state.bt; r = app_state.analysis; d = app_state.data;
    n = size(bt.strategy_value, 1);
    restore_axes(ax, gui.ph_eq);
    x = (1:n)';
    plot(x, bt.buyhold_value); style_last([120 130 145], 2, 1);
    plot(x, bt.strategy_value); style_last([20 110 60], 2, 1);
    labels = ["Buy & hold", "StockVision strategy"];   // creation order
    pos = bt.position; prev = [0; pos(1:$-1)];
    buys = find(pos == 1 & prev == 0); sells = find(pos == 0 & prev == 1);
    if ~isempty(buys) then
        plot(buys, bt.strategy_value(buys), "^");
        e = gce(); e.children(1).mark_background = color(30, 170, 60); e.children(1).mark_foreground = color(0, 90, 20);
        e.children(1).mark_size = 7; labels = [labels, "BUY executed"];
    end
    if ~isempty(sells) then
        plot(sells, bt.strategy_value(sells), "v");
        e = gce(); e.children(1).mark_background = color(220, 50, 50); e.children(1).mark_foreground = color(120, 0, 0);
        e.children(1).mark_size = 7; labels = [labels, "SELL executed"];
    end
    allv = [bt.strategy_value; bt.buyhold_value];
    pad = 0.08 * (max(allv) - min(allv) + 1e-9);
    ax.data_bounds = [1, min(allv) - pad; n, max(allv) + pad];
    ax.tight_limits = "on";
    set_date_ticks(ax, d.dates(r.test_idx), 1, n);
    ax.title.text = "Portfolio value on the test window (same period for both)"; ax.title.font_size = 3;
    ax.y_label.text = "Value"; ax.x_label.text = "";
    lg = legend(labels, "in_lower_right"); lg.font_size = 2;
    ax.margins = [0.17, 0.06, 0.04, 0.17];
endfunction


// ---------------------------------------------------------------------------
// Text panels
// ---------------------------------------------------------------------------
function a = current_assumptions()
    // Assumptions for the info panel; falls back to defaults when an edit
    // box is invalid so the panel never goes blank.
    global app_state
    [ok, p, msg] = read_params();
    if ~ok then
        p = struct("buy", 0.5, "sell", -0.5, "capital", 100000, "cost", 0, "slip", 0);
    end
    cfg = struct("capital", p.capital, "cost", p.cost, "slip", p.slip, "buy", p.buy, ..
                 "sell", p.sell, "split_ratio", app_state.split_ratio);
    a = assumptions_struct(app_state.data, app_state.dq, cfg);
endfunction


function show_info_tab(name)
    // Top-right panel shows either the data-quality block or the assumptions.
    global gui app_state
    app_state.info_tab = name;
    if name == "asm" then
        set_list(gui.lb_info, app_state.info_asm);
        set(gui.tab_asm, "fontweight", "bold"); set(gui.tab_dq, "fontweight", "normal");
    else
        set_list(gui.lb_info, app_state.info_dq);
        set(gui.tab_dq, "fontweight", "bold"); set(gui.tab_asm, "fontweight", "normal");
    end
endfunction


function refresh_dq()
    global gui app_state
    if ~has(app_state.data) then
        app_state.info_dq = ["No dataset loaded."];
    else
        app_state.dq = data_quality_summary(app_state.data, app_state.split_ratio);
        app_state.info_dq = format_data_quality(app_state.dq, dataset_label());
    end
    if app_state.info_tab == "dq" then show_info_tab("dq"); end
endfunction


function s = dataset_label()
    global app_state
    if app_state.dataset_idx <= size(app_state.dataset_labels, 2) then
        s = app_state.dataset_labels(app_state.dataset_idx);
    else
        s = "Custom: " + app_state.custom_path;
    end
endfunction


function refresh_assumptions()
    global gui app_state
    if ~has(app_state.data) then return; end
    app_state.info_asm = format_assumptions(current_assumptions());
    if app_state.info_tab == "asm" then show_info_tab("asm"); end
endfunction


function refresh_results()
    global gui app_state
    if ~has(app_state.analysis) then
        set_list(gui.lb_res, ["No analysis yet.", " ", "1. Pick a dataset and model.", "2. Click Run Analysis."]);
        return
    end
    sig = app_state.signal;
    set_list(gui.lb_res, format_model_results(app_state.analysis, app_state.naive, sig, has(app_state.cmp)));
endfunction


function refresh_comparison()
    global gui app_state
    if ~has(app_state.cmp) then
        set_list(gui.lb_cmp, ["No comparison yet.", " ", "Click Compare Models to evaluate Naive, LR, AR and ES", ..
                              "on the same data, split and test window."]);
        set_list(gui.lb_wf, ["No walk-forward validation yet.", " ", "Click Walk Forward Validation (or Compare Models)."]);
    else
        c = app_state.cmp;
        set_list(gui.lb_cmp, [format_comparison(c); " "; format_ranking(c)]);
        set_list(gui.lb_wf, format_walk_forward(c.wf));
    end
endfunction


function refresh_backtest()
    global gui app_state
    if ~has(app_state.bt) then
        set_list(gui.lb_bt, ["No backtest yet.", " ", "Run Analysis first, then click Run Backtest."]);
        set(gui.strip, "string", "  Backtest summary: not run yet");
    else
        set_list(gui.lb_bt, format_backtest(app_state.bt, app_state.analysis.name));
        set(gui.strip, "string", "  " + format_backtest_headline(app_state.bt));
    end
endfunction


function refresh_all()
    global gui
    refresh_dq(); refresh_assumptions(); refresh_results(); refresh_comparison(); refresh_backtest();
    gui.fig.immediate_drawing = "off";
    draw_main_chart(); draw_comparison_chart(); draw_equity_chart();
    gui.fig.immediate_drawing = "on";
    set_button_states();
endfunction


// ---------------------------------------------------------------------------
// State changes and actions
// ---------------------------------------------------------------------------
function ok = load_current_dataset()
    // Loads the selected CSV into app_state; shows a clear error otherwise.
    global gui app_state
    ok = %f;
    if app_state.dataset_idx <= size(app_state.dataset_files, 2) then
        path = app_state.dataset_files(app_state.dataset_idx);
    else
        path = app_state.custom_path;
    end
    set_status("Loading dataset...");
    try
        d = load_dataset(path);
    catch
        msg = lasterror();
        app_state.data = []; app_state.dq = [];
        set_status("Could not load dataset (see message).", "error");
        show_dialog("Dataset error", msg, "error");
        return
    end
    set_status("Validating data...");
    app_state.data = d;
    app_state.dq = data_quality_summary(d, app_state.split_ratio);
    ok = %t;
    if size(d.warnings, 1) > 0 then
        set_status("Loaded with warnings: " + strcat(d.warnings, " "), "info");
    end
endfunction


function invalidate(level, why)
    // Drops results that no longer match the settings, so stale numbers can
    // never stay on screen. level: "all", "model", "cmp", "bt".
    global app_state
    select level
    case "all" then
        app_state.analysis = []; app_state.naive = []; app_state.signal = [];
        app_state.cmp = []; app_state.bt = [];
    case "model" then
        app_state.analysis = []; app_state.naive = []; app_state.signal = []; app_state.bt = [];
    case "cmp" then
        app_state.cmp = [];
    case "bt" then
        app_state.bt = [];
    end
    refresh_all();
    if argn(2) >= 2 then set_status(why, "info"); end
endfunction


function on_dataset_changed()
    global gui app_state
    app_state.dataset_idx = get(gui.dataset_popup, "value");
    if load_current_dataset() then
        invalidate("all", "Dataset changed -- previous results cleared. Click Run Analysis.");
    else
        invalidate("all");
    end
endfunction


function on_model_changed()
    global gui app_state
    idx = get(gui.model_popup, "value");
    keys = ["LR", "AR", "ES"];
    app_state.model_type = keys(idx);
    invalidate("model", "Model changed -- click Run Analysis.");
endfunction


function on_slider_moved()
    global gui app_state
    v = round(get(gui.split_slider, "value") * 100) / 100;
    if abs(v - app_state.split_ratio) < 1e-9 then return; end
    app_state.split_ratio = v;
    set(gui.split_label, "string", "Train/test split: " + string(round(v*100)) + "% / " + string(round((1-v)*100)) + "%");
    if has(app_state.data) then
        invalidate("all", "Split changed -- previous results cleared. Click Run Analysis.");
    end
endfunction


function on_ma_toggled()
    global gui app_state
    app_state.show_ma = (get(gui.cb_ma, "value") == 1);
    draw_main_chart();
endfunction


function on_model_params_changed()
    // AR lookback or fold count edited.
    global gui app_state
    [ok, lb, nf, msg] = read_model_params();
    if ~ok then set_status(msg, "error"); return; end
    if lb <> app_state.ar_lookback then
        app_state.ar_lookback = lb; app_state.n_folds = nf;
        invalidate("all", "AR lookback changed -- previous results cleared.");
    elseif nf <> app_state.n_folds then
        app_state.n_folds = nf;
        invalidate("cmp", "Fold count changed -- comparison cleared. Click Compare Models.");
    end
endfunction


function on_strategy_changed()
    // Thresholds, capital, costs or slippage edited.
    global gui app_state
    [ok, p, msg] = read_params();
    if ~ok then set_status(msg, "error"); return; end
    refresh_assumptions();
    if has(app_state.analysis) then
        r = app_state.analysis;
        app_state.signal = make_signal(r, p);
        refresh_results();
    end
    if has(app_state.bt) then
        invalidate("bt", "Strategy settings changed -- backtest cleared. Click Run Backtest.");
    else
        set_status("Strategy settings updated.", "info");
    end
endfunction


function sig = make_signal(r, p)
    global app_state
    cur = app_state.data.close($);
    sig = generate_signal(cur, r.next_price, p.buy, p.sell);
    sig.current_price = cur; sig.buy_thr = p.buy; sig.sell_thr = p.sell;
endfunction


function on_run_analysis()
    global gui app_state ES_ALPHA ES_BETA
    if ~has(app_state.data) then set_status("Load a dataset first.", "error"); return; end
    [ok, lb, nf, msg] = read_model_params();
    if ~ok then set_status(msg, "error"); return; end
    [ok2, p, msg2] = read_params();
    if ~ok2 then set_status(msg2, "error"); return; end
    app_state.ar_lookback = lb; app_state.n_folds = nf;
    set_status("Validating data...");
    split_cal = round(app_state.data.n * app_state.split_ratio);
    try
        set_status("Training " + model_display_name(app_state.model_type) + "...");
        r = run_model(app_state.data, app_state.model_type, split_cal, lb, ES_ALPHA, ES_BETA);
        set_status("Evaluating naive baseline on the same test window...");
        nv = run_model(app_state.data, "NAIVE", split_cal, lb, ES_ALPHA, ES_BETA);
    catch
        err = lasterror();
        set_status("Analysis failed: " + err, "error");
        show_dialog("Analysis error", err, "error");
        return
    end
    app_state.analysis = r; app_state.naive = nv; app_state.bt = [];
    app_state.signal = make_signal(r, p);
    set_status("Updating dashboard...");
    refresh_all();
    set_status("Analysis complete.", "ok");
endfunction


function ensure_comparison()
    // Runs all models + walk-forward on the common window if needed.
    global gui app_state ES_ALPHA ES_BETA
    [ok, lb, nf, msg] = read_model_params();
    if ~ok then error(msg); end
    app_state.ar_lookback = lb; app_state.n_folds = nf;
    set_status("Training Naive, Linear Regression, AR and Exponential Smoothing...");
    set_status("Running walk-forward validation...");
    app_state.cmp = compare_models(app_state.data, app_state.split_ratio, lb, ES_ALPHA, ES_BETA, nf);
endfunction


function adopt_selected_model_from_comparison()
    // When Compare runs first, the chart/results panels still show the selected model.
    global app_state
    [ok, p, msg] = read_params();
    if ~ok then return; end
    kmap = ["LR", "AR", "ES"];
    k = find(kmap == app_state.model_type) + 1;
    app_state.analysis = app_state.cmp.results(k);
    app_state.naive = app_state.cmp.results(1);
    app_state.signal = make_signal(app_state.analysis, p);
endfunction


function on_compare()
    global gui app_state
    if ~has(app_state.data) then set_status("Load a dataset first.", "error"); return; end
    try
        ensure_comparison();
    catch
        err = lasterror();
        set_status("Comparison failed: " + err, "error");
        show_dialog("Comparison error", err, "error");
        return
    end
    if ~has(app_state.analysis) then adopt_selected_model_from_comparison(); end
    set_status("Updating dashboard...");
    refresh_all();
    rk = app_state.cmp.rank;
    msg = "Comparison complete. Best StockVision model: " + app_state.cmp.labels(rk.best_idx);
    if rk.naive_rank_pos == 1 then msg = msg + " (naive baseline ranks first overall)"; end
    set_status(msg + ".", "ok");
endfunction


function on_walk_forward()
    global gui app_state
    if ~has(app_state.data) then set_status("Load a dataset first.", "error"); return; end
    try
        ensure_comparison();
    catch
        err = lasterror();
        set_status("Walk-forward failed: " + err, "error");
        show_dialog("Walk-forward error", err, "error");
        return
    end
    if ~has(app_state.analysis) then adopt_selected_model_from_comparison(); end
    refresh_all();
    wf = app_state.cmp.wf;
    msg = "Walk-forward validation complete: " + string(wf.n_used) + " fold(s)";
    if wf.reason <> "" then msg = msg + " -- " + wf.reason; end
    set_status(msg, "ok");
endfunction


function on_run_backtest()
    global gui app_state
    if ~has(app_state.analysis) then set_status("Run Analysis first.", "error"); return; end
    [ok, p, msg] = read_params();
    if ~ok then set_status(msg, "error"); return; end
    set_status("Running backtest...");
    r = app_state.analysis;
    try
        app_state.bt = run_backtest(r.y_true, r.y_pred, p.buy, p.sell, p.capital, p.cost, p.slip);
    catch
        err = lasterror();
        set_status("Backtest failed: " + err, "error");
        show_dialog("Backtest error", err, "error");
        return
    end
    set_status("Updating dashboard...");
    refresh_all();
    show_info_tab("asm");
    set_status("Backtest complete.", "ok");
endfunction


function rep = build_rep()
    // Everything an export needs, taken from the current dashboard state.
    global app_state ES_ALPHA ES_BETA
    [ok, p, msg] = read_params();
    cfg = struct("split_ratio", app_state.split_ratio, "ar_lookback", app_state.ar_lookback, ..
                 "es_alpha", ES_ALPHA, "es_beta", ES_BETA, "n_folds", app_state.n_folds, ..
                 "buy", p.buy, "sell", p.sell, "cost", p.cost, "slip", p.slip, "capital", p.capital);
    rep = struct("dataset_label", dataset_label(), "data", app_state.data, "dq", app_state.dq, ..
                 "cfg", cfg, "analysis", app_state.analysis, "naive", app_state.naive, ..
                 "signal", app_state.signal, "validated", has(app_state.cmp), ..
                 "cmp", app_state.cmp, "bt", app_state.bt, "assump", current_assumptions());
endfunction


function msg = export_to(path)
    global APP_DIR
    // Writes .txt (full report + companion CSVs), .csv (single table) or
    // .pdf (the dashboard charts). Never overwrites: a free name is chosen.
    global gui app_state
    [pth, nm, ext] = fileparts(path);
    ext = convstr(ext, "l");
    if pth == "" then pth = APP_DIR + "outputs/exports/"; end
    if ~isdir(pth) then mkdir(pth); end
    target = unique_path(pth + nm + ext);
    rep = build_rep();
    select ext
    case ".txt" then
        export_report_txt(target, rep);
        [p2, n2, e2] = fileparts(target);
        extra = export_companion_csvs(p2 + n2, rep);
        msg = "Exported report + " + string(size(extra, 1)) + " CSV file(s): " + target;
    case ".csv" then
        export_results_csv(target, rep);
        msg = "Exported CSV: " + target;
    case ".pdf" then
        xs2pdf(gui.fig, target);
        msg = "Exported dashboard charts (PDF): " + target;
    else
        error("Unsupported export type [" + ext + "] -- use .txt, .csv or .pdf.");
    end
endfunction


function on_export()
    global gui app_state gui_quiet APP_DIR
    if ~has(app_state.analysis) then set_status("Run Analysis first.", "error"); return; end
    c = clock();
    stamp = msprintf("%04d%02d%02d_%02d%02d%02d", c(1), c(2), c(3), c(4), c(5), floor(c(6)));
    default_name = "StockVision_" + app_state.model_type + "_" + stamp + ".txt";
    outdir = APP_DIR + "outputs/exports/";
    if ~isdir(outdir) then mkdir(outdir); end
    if gui_quiet then
        path = outdir + default_name;
    else
        path = uiputfile(["*.txt"; "*.csv"; "*.pdf"], outdir + default_name, "Export results (.txt = full report + CSVs)");
        if path == "" then set_status("Export cancelled.", "info"); return; end
    end
    set_status("Exporting results...");
    try
        msg = export_to(path);
    catch
        err = lasterror();
        set_status("Export failed: " + err, "error");
        show_dialog("Export error", err, "error");
        return
    end
    set_status(msg, "ok");
endfunction


function on_model_info()
    global app_state ES_ALPHA ES_BETA
    lines = model_info_text(app_state.model_type, app_state.ar_lookback, ES_ALPHA, ES_BETA);
    lines = [lines; " "; "Evaluation protocol (all models):"; ..
        "  - chronological split, never shuffled; same test window for all"; ..
        "  - scaling/fit parameters come from training rows only"; ..
        "  - the forecast for day t uses data up to day t-1 only"; ..
        "  - a naive last-value baseline is always reported alongside"];
    show_dialog("Model Info", lines, "info");
    set_status("Model info shown.", "info");
endfunction


function on_about()
    show_dialog("About StockVision", ["StockVision -- stock analysis & prediction dashboard (Scilab)."; ..
        "Linear Regression, AR and Holt exponential smoothing vs a naive baseline,"; ..
        "walk-forward validation and a backtest vs buy & hold."; " "; ..
        "Educational tool, not financial advice. Bundled data is synthetic."], "info");
endfunction


function use_custom_csv(path)
    // Selects a custom CSV as the active dataset and clears stale results.
    global gui app_state
    app_state.custom_path = path;
    app_state.dataset_idx = size(app_state.dataset_labels, 2) + 1;
    names = [app_state.dataset_labels, "Custom: " + basename(path)];
    set(gui.dataset_popup, "string", strcat(names, "|"));
    set(gui.dataset_popup, "value", app_state.dataset_idx);
    if load_current_dataset() then
        invalidate("all", "Custom dataset loaded. Click Run Analysis.");
    else
        invalidate("all");
    end
endfunction


function on_load_custom_csv()
    path = uigetfile(["*.csv"], "", "Select a CSV (Date,Open,High,Low,Close,Volume)");
    if path == "" then return; end
    use_custom_csv(path);
endfunction


function on_reset()
    global gui app_state
    set(gui.dataset_popup, "string", strcat(app_state.dataset_labels, "|"));
    set(gui.dataset_popup, "value", 1); app_state.dataset_idx = 1;
    set(gui.model_popup, "value", 1); app_state.model_type = "LR";
    set(gui.split_slider, "value", 0.8); app_state.split_ratio = 0.8;
    set(gui.split_label, "string", "Train/test split: 80% / 20%");
    set(gui.cb_ma, "value", 1); app_state.show_ma = %t;
    set(gui.ed_lookback, "string", "10"); app_state.ar_lookback = 10;
    set(gui.ed_folds, "string", "5"); app_state.n_folds = 5;
    set(gui.ed_buy, "string", "0.5"); set(gui.ed_sell, "string", "-0.5");
    set(gui.ed_capital, "string", "100000");
    set(gui.ed_cost, "string", "0.1"); set(gui.ed_slip, "string", "0.05");
    if load_current_dataset() then
        invalidate("all", "Reset to defaults. No analysis yet.");
    else
        invalidate("all");
    end
    show_info_tab("dq");
endfunction


// ---------------------------------------------------------------------------
// Layout: all positions are normalized (origin bottom-left) so the dashboard
// scales with the window.
// ---------------------------------------------------------------------------
HEAD_H = 0.024;

function h = mk_text(str, x, y, w, hh, bold, align)
    global gui GUI_BG
    h = uicontrol(gui.fig, "style", "text", "string", str, "units", "normalized", ..
                  "position", [x y w hh], "backgroundcolor", GUI_BG, "fontsize", 11, ..
                  "horizontalalignment", align);
    if bold then set(h, "fontweight", "bold"); end
endfunction


function h = mk_head(str, x, y, w)
    // Dark section heading bar whose top edge is at y + HEAD_H.
    global gui GUI_HEAD
    h = uicontrol(gui.fig, "style", "text", "string", " " + str, "units", "normalized", ..
                  "position", [x y w 0.024], "backgroundcolor", GUI_HEAD, ..
                  "foregroundcolor", [1 1 1], "fontweight", "bold", "fontsize", 11, ..
                  "horizontalalignment", "left");
endfunction


function h = mk_edit(str, x, y, w, cb, tip)
    global gui
    h = uicontrol(gui.fig, "style", "edit", "string", str, "units", "normalized", ..
                  "position", [x y w 0.026], "backgroundcolor", [1 1 1], "fontsize", 11, ..
                  "callback", cb, "tooltipstring", tip);
endfunction


function h = mk_button(str, x, y, w, cb, tip)
    global gui
    h = uicontrol(gui.fig, "style", "pushbutton", "string", str, "units", "normalized", ..
                  "position", [x y w 0.040], "fontsize", 11, "fontweight", "bold", ..
                  "callback", cb, "tooltipstring", tip);
endfunction


function [lb, hd] = mk_list_panel(title, x, y, w, hh)
    // Heading + monospaced listbox filling the rest of the panel.
    global gui
    hd = mk_head(title, x, y + hh - 0.024, w);
    lb = uicontrol(gui.fig, "style", "listbox", "units", "normalized", ..
                   "position", [x y w hh - 0.024], "backgroundcolor", [1 1 1], ..
                   "fontname", "Monospaced", "fontsize", 9);
endfunction


function [ax, hd] = mk_axes_panel(title, x, y, w, hh)
    hd = mk_head(title, x, y + hh - 0.024, w);
    ax = make_axes(x, y, w, hh - 0.024);
endfunction


// --- figure -----------------------------------------------------------------
scr = get(0, "screensize_px");
fig_w = min(1500, scr(3) - 20); fig_h = min(980, scr(4) - 60);
gui.fig = figure("figure_name", "StockVision -- Stock Analysis & Prediction (Scilab)", ..
                 "position", [5, 5, fig_w, fig_h], "dockable", "off");
gui.fig.background = color(236, 238, 241);
toolbar(gui.fig.figure_id, "off");
for nm = ["File", "Tools", "Edit", "?"]
    delmenu(gui.fig.figure_id, nm);
end
for k = size(gui.fig.children, "*"):-1:1
    if gui.fig.children(k).type == "Axes" then delete(gui.fig.children(k)); end
end
gui.fig.immediate_drawing = "off";

m_file = uimenu(gui.fig, "label", "File");
uimenu(m_file, "label", "Load Custom CSV...", "callback", "on_load_custom_csv()");
uimenu(m_file, "label", "Export Results...", "callback", "on_export()");
uimenu(m_file, "label", "Exit", "callback", "close(gui.fig)");
m_help = uimenu(gui.fig, "label", "Help");
uimenu(m_help, "label", "Model Info", "callback", "on_model_info()");
uimenu(m_help, "label", "About", "callback", "on_about()");

// --- title band ---------------------------------------------------------------
gui.title = uicontrol(gui.fig, "style", "text", "string", "  STOCKVISION", "units", "normalized", ..
    "position", [0 0.946 0.20 0.054], "backgroundcolor", GUI_HEAD, "foregroundcolor", [1 1 1], ..
    "fontsize", 22, "fontweight", "bold", "horizontalalignment", "left");
gui.subtitle = uicontrol(gui.fig, "style", "text", "units", "normalized", ..
    "string", "Stock analysis & prediction dashboard  |  Linear Regression, AR and Exponential Smoothing vs a naive baseline  |  built with Scilab", ..
    "position", [0.20 0.946 0.80 0.054], "backgroundcolor", GUI_HEAD, "foregroundcolor", [0.85 0.9 1], ..
    "fontsize", 12, "horizontalalignment", "left");

// --- left column: controls ------------------------------------------------------
LX = 0.006; LW = 0.190;
mk_head("DATASET & MODEL", LX, 0.915, LW);
mk_text("Dataset", LX, 0.888, LW, 0.022, %f, "left");
gui.dataset_popup = uicontrol(gui.fig, "style", "popupmenu", "string", strcat(app_state.dataset_labels, "|"), ..
    "units", "normalized", "position", [LX 0.858 LW 0.028], "fontsize", 11, "value", 1, ..
    "callback", "on_dataset_changed()", "tooltipstring", "Bundled synthetic datasets, or File > Load Custom CSV");
mk_text("Model", LX, 0.830, LW, 0.022, %f, "left");
gui.model_popup = uicontrol(gui.fig, "style", "popupmenu", ..
    "string", "Linear Regression|AR Time-Series|Exponential Smoothing", ..
    "units", "normalized", "position", [LX 0.800 LW 0.028], "fontsize", 11, "value", 1, ..
    "callback", "on_model_changed()", "tooltipstring", "Model analysed by Run Analysis and Run Backtest");

mk_head("PARAMETERS", LX, 0.765, LW);
mk_text("Train / test split", LX, 0.738, LW, 0.022, %f, "left");
gui.split_slider = uicontrol(gui.fig, "style", "slider", "min", 0.5, "max", 0.95, "value", 0.8, ..
    "units", "normalized", "position", [LX 0.714 LW 0.022], "callback", "on_split_moved_wrapper()", ..
    "tooltipstring", "Share of rows used for training. The rest is the test window.");
gui.split_label = mk_text("Train/test split: 80% / 20%", LX, 0.690, LW, 0.022, %f, "left");
gui.cb_ma = uicontrol(gui.fig, "style", "checkbox", "string", "Show 20-day moving average", "value", 1, ..
    "units", "normalized", "position", [LX 0.660 LW 0.026], "fontsize", 11, "backgroundcolor", GUI_BG, ..
    "callback", "on_ma_toggled()");
mk_text("AR lookback (days)", LX, 0.630, 0.125, 0.024, %f, "left");
gui.ed_lookback = mk_edit("10", 0.133, 0.630, 0.063, "on_model_params_changed()", "Past closes used by the AR model (2-60)");
mk_text("Walk-forward folds", LX, 0.598, 0.125, 0.024, %f, "left");
gui.ed_folds = mk_edit("5", 0.133, 0.598, 0.063, "on_model_params_changed()", "Requested folds (1-10); reduced automatically if data is short");
mk_text("Exp. smoothing: alpha 0.30, beta 0.10 (fixed)", LX, 0.568, LW, 0.022, %f, "left");

mk_head("STRATEGY & COSTS", LX, 0.535, LW);
mk_text("BUY if forecast >= (%)", LX, 0.508, 0.125, 0.024, %f, "left");
gui.ed_buy = mk_edit("0.5", 0.133, 0.508, 0.063, "on_strategy_changed()", "BUY when predicted change is at least this percent");
mk_text("SELL if forecast <= (%)", LX, 0.478, 0.125, 0.024, %f, "left");
gui.ed_sell = mk_edit("-0.5", 0.133, 0.478, 0.063, "on_strategy_changed()", "SELL (exit) when predicted change is at most this percent");
mk_text("Starting capital", LX, 0.448, 0.125, 0.024, %f, "left");
gui.ed_capital = mk_edit("100000", 0.133, 0.448, 0.063, "on_strategy_changed()", "Initial portfolio value for the backtest");
mk_text("Transaction cost (%)", LX, 0.418, 0.125, 0.024, %f, "left");
gui.ed_cost = mk_edit("0.1", 0.133, 0.418, 0.063, "on_strategy_changed()", "Percent of portfolio value per executed trade");
mk_text("Slippage (%)", LX, 0.388, 0.125, 0.024, %f, "left");
gui.ed_slip = mk_edit("0.05", 0.133, 0.388, 0.063, "on_strategy_changed()", "Extra percent per executed trade");

mk_head("ACTIONS", LX, 0.350, LW);
gui.btn_run = mk_button("Run Analysis", LX, 0.303, LW, "on_run_analysis()", "Fit the selected model and evaluate it on the test window");
gui.btn_compare = mk_button("Compare Models", LX, 0.259, LW, "on_compare()", "Naive vs LR vs AR vs ES on the same window, with ranking");
gui.btn_backtest = mk_button("Run Backtest", LX, 0.215, LW, "on_run_backtest()", "Trade the model signals vs buy & hold (needs Run Analysis)");
gui.btn_wf = mk_button("Walk Forward Validation", LX, 0.171, LW, "on_walk_forward()", "Expanding-window validation over several chronological folds");
gui.btn_export = mk_button("Export Results", LX, 0.127, LW, "on_export()", "Save report (.txt) + CSV tables, a CSV, or chart PDF");
gui.btn_info = mk_button("Model Info", LX, 0.083, 0.093, "on_model_info()", "Assumptions and limitations of the selected model");
gui.btn_reset = mk_button("Reset", LX + 0.097, 0.083, 0.093, "on_reset()", "Restore default settings and clear results");

// --- right area: dashboard panels ----------------------------------------------
RX = 0.202;
function ph = mk_placeholder(x, y, w, hh)
    // White frame + centred grey text shown while a chart has no data yet.
    global gui
    fr = uicontrol(gui.fig, "style", "frame", "units", "normalized", "position", [x y w hh], ..
                   "backgroundcolor", [1 1 1]);
    tx = uicontrol(gui.fig, "style", "text", "string", "", "units", "normalized", ..
                   "position", [x, y + hh/2 - 0.015, w, 0.03], "backgroundcolor", [1 1 1], ..
                   "foregroundcolor", [0.5 0.5 0.5], "fontsize", 13, "horizontalalignment", "center");
    ph = list(fr, tx);
endfunction


// Row A: main chart + info panel (data quality / assumptions tabs)
gui.head_main = mk_head("PRICE & PREDICTION", RX, 0.658 + 0.282 - 0.024, 0.498);
gui.key_main = uicontrol(gui.fig, "style", "text", "string", "", "units", "normalized", ..
    "position", [RX 0.658 + 0.282 - 0.024 - 0.024 0.498 0.024], "backgroundcolor", [1 1 1], "fontsize", 10, ..
    "horizontalalignment", "left");
gui.ax_main = make_axes(RX, 0.658, 0.498, 0.282 - 0.048);
[gui.lb_info, gui.head_info] = mk_list_panel("INFO", 0.706, 0.658, 0.288, 0.282);
gui.tab_dq = uicontrol(gui.fig, "style", "pushbutton", "string", "Data Quality", "units", "normalized", ..
    "position", [0.790 0.9165 0.100 0.022], "fontsize", 10, "callback", "show_info_tab(""dq"")", ..
    "tooltipstring", "Rows, date range, missing/duplicate/invalid rows, train/test rows");
gui.tab_asm = uicontrol(gui.fig, "style", "pushbutton", "string", "Assumptions", "units", "normalized", ..
    "position", [0.892 0.9165 0.100 0.022], "fontsize", 10, "callback", "show_info_tab(""asm"")", ..
    "tooltipstring", "Capital, costs, slippage, signal lag, position rule, periods");
// Row B: results + comparison/ranking + comparison chart
[gui.lb_res, gui.head_res] = mk_list_panel("MODEL RESULTS", RX, 0.340, 0.205, 0.315);
[gui.lb_cmp, gui.head_cmp] = mk_list_panel("MODEL COMPARISON & RANKING", 0.412, 0.340, 0.288, 0.315);
[gui.ax_cmp, gui.head_cmpchart] = mk_axes_panel("MODEL COMPARISON CHART", 0.706, 0.340, 0.288, 0.315);
// Backtest summary strip
gui.strip = uicontrol(gui.fig, "style", "text", "string", "  Backtest summary: not run yet", "units", "normalized", ..
    "position", [RX 0.316 0.792 0.022], "backgroundcolor", [0.86 0.90 0.95], "fontsize", 12, ..
    "fontweight", "bold", "horizontalalignment", "left");
// Row C: equity chart + backtest summary + walk-forward
[gui.ax_eq, gui.head_eq] = mk_axes_panel("BACKTEST: EQUITY CURVE", RX, 0.044, 0.290, 0.268);
[gui.lb_bt, gui.head_bt] = mk_list_panel("BACKTEST SUMMARY (strategy vs buy & hold)", 0.497, 0.044, 0.203, 0.268);
[gui.lb_wf, gui.head_wf] = mk_list_panel("WALK-FORWARD VALIDATION", 0.706, 0.044, 0.288, 0.268);

gui.ph_main = mk_placeholder(RX, 0.658, 0.498, 0.234);
gui.ph_cmp = mk_placeholder(0.706, 0.340, 0.288, 0.291);
gui.ph_eq = mk_placeholder(RX, 0.044, 0.290, 0.244);

// --- status bar -------------------------------------------------------------------
gui.status = uicontrol(gui.fig, "style", "text", "string", " Ready.", "units", "normalized", ..
    "position", [0 0 1 0.036], "backgroundcolor", [0.82 0.84 0.88], "foregroundcolor", [0.15 0.15 0.15], ..
    "fontsize", 12, "fontweight", "bold", "horizontalalignment", "left");


function on_split_moved_wrapper()
    // The slider fires continuously; on_slider_moved ignores unchanged values.
    on_slider_moved();
endfunction


// --- start -----------------------------------------------------------------------
if load_current_dataset() then
    refresh_all();
    show_info_tab("dq");
    set_status("Ready. Choose a model and click Run Analysis (or Compare Models).", "info");
else
    refresh_all();
end
gui.fig.immediate_drawing = "on";
