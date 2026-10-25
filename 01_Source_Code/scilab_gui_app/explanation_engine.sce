// ============================================================================
// explanation_engine.sce -- StockVision AI Explanation Assistant & Forecast Intelligence
//
// Pure Scilab quantitative intelligence layer that converts computed forecasts,
// model comparisons, evaluation metrics, prediction intervals, and data-quality
// metadata into rigorous, evidence-grounded natural-language briefings.
//
// Operating Modes:
//   - Mode A (Required): Fully deterministic, offline mathematical explanation engine.
//     Works with zero internet connection and zero API keys. 100% reproducible.
//   - Mode B (Optional): Evidence-grounded natural language briefing via Google Gemini API.
//     Strictly bounded by computed snapshot facts with automatic fallback to Mode A.
//
// Headless & pure: No GUI dependencies. Can be tested standalone or invoked
// from gui_app.sce callbacks.
//
// Load with: exec("explanation_engine.sce", -1);
// ============================================================================

global EE_SCRIPT_DIR;
try
    EE_SCRIPT_DIR = get_absolute_file_path("explanation_engine.sce");
catch
    if ~exists("EE_SCRIPT_DIR") then EE_SCRIPT_DIR = ""; end
end


// ---------------------------------------------------------------------------
// 1. Path and Directory Helpers
// ---------------------------------------------------------------------------

function p = ee_engine_dir()
    // Returns the directory containing this script.
    global EE_SCRIPT_DIR APP_DIR;
    if exists("EE_SCRIPT_DIR") & EE_SCRIPT_DIR <> "" & isdir(EE_SCRIPT_DIR) then
        p = EE_SCRIPT_DIR;
        return;
    end
    if exists("APP_DIR") & APP_DIR <> "" & isdir(APP_DIR) then
        p = APP_DIR;
        return;
    end
    try
        p = get_absolute_file_path("explanation_engine.sce");
        EE_SCRIPT_DIR = p;
        return;
    catch
        cand = pwd() + filesep();
        if isfile(cand + "explanation_engine.sce") then
            p = cand;
            return;
        end
        if isdir(cand + "01_Source_Code" + filesep() + "scilab_gui_app") then
            p = cand + "01_Source_Code" + filesep() + "scilab_gui_app" + filesep();
            return;
        end
        p = cand;
    end
endfunction


function p = ee_project_root()
    // Locates the project root (contains config/ or 01_Source_Code/).
    edir = ee_engine_dir();
    // 1. Check 2 levels up from engine dir
    cand = edir + ".." + filesep() + ".." + filesep();
    if isdir(cand + "config") | isdir(cand + "01_Source_Code") then
        p = cand;
        return;
    end
    // 2. Check 1 level up from engine dir
    cand = edir + ".." + filesep();
    if isdir(cand + "config") | isdir(cand + "01_Source_Code") then
        p = cand;
        return;
    end
    // 3. Engine dir itself
    if isdir(edir + "config") then
        p = edir;
        return;
    end
    // 4. Check pwd()
    cand = pwd() + filesep();
    if isdir(cand + "config") | isdir(cand + "01_Source_Code") then
        p = cand;
        return;
    end
    // 5. Check 2 levels up from pwd()
    cand = pwd() + filesep() + ".." + filesep() + ".." + filesep();
    if isdir(cand + "config") | isdir(cand + "01_Source_Code") then
        p = cand;
        return;
    end
    p = edir;
endfunction


// ---------------------------------------------------------------------------
// 2. Configuration Management & Credential Security
// ---------------------------------------------------------------------------

function cfg = ee_default_config()
    cfg = struct();
    cfg.provider = "gemini";
    cfg.api_key = "";
    cfg.model = "gemini-1.5-flash";
    cfg.timeout_seconds = 15;
    cfg.temperature = 0.2;
    cfg.max_output_tokens = 1000;
    cfg.fallback_to_offline = %t;
    cfg.attribution = "Natural language explanation powered by Google Gemini API";
    cfg.base_url = "https://generativelanguage.googleapis.com/v1beta/models";
    cfg.mock_response_file = "";
endfunction


function cfg = ee_load_config(custom_path)
    // Loads configuration from config/ai_config.json or environment variables.
    // Environment variables (STOCKVISION_AI_KEY, GEMINI_API_KEY) take highest precedence.
    cfg = ee_default_config();

    config_path = "";
    if argn(2) >= 1 & custom_path <> "" then
        if isfile(custom_path) then config_path = custom_path; end
    end
    if config_path == "" then
        root = ee_project_root();
        cand1 = root + "config" + filesep() + "ai_config.json";
        cand2 = root + "config" + filesep() + "ai_config.json.example";
        if isfile(cand1) then
            config_path = cand1;
        elseif isfile(cand2) then
            config_path = cand2;
        end
    end

    if config_path <> "" & isfile(config_path) then
        try
            lines = mgetl(config_path);
            raw = strcat(lines, "");
            parsed = fromJSON(raw);
            if isfield(parsed, "provider") then cfg.provider = parsed.provider; end
            if isfield(parsed, "api_key") then
                if parsed.api_key <> "YOUR_GEMINI_API_KEY_HERE" then
                    cfg.api_key = parsed.api_key;
                end
            end
            if isfield(parsed, "model") then cfg.model = parsed.model; end
            if isfield(parsed, "timeout_seconds") then cfg.timeout_seconds = parsed.timeout_seconds; end
            if isfield(parsed, "temperature") then cfg.temperature = parsed.temperature; end
            if isfield(parsed, "max_output_tokens") then cfg.max_output_tokens = parsed.max_output_tokens; end
            if isfield(parsed, "fallback_to_offline") then cfg.fallback_to_offline = parsed.fallback_to_offline; end
            if isfield(parsed, "attribution") then cfg.attribution = parsed.attribution; end
            if isfield(parsed, "base_url") then cfg.base_url = parsed.base_url; end
        catch
            // Fall back to defaults on corrupt config file
        end
    end

    // Environment variables override file config for security
    env_key = getenv("STOCKVISION_AI_KEY", "");
    if env_key == "" then
        env_key = getenv("GEMINI_API_KEY", "");
    end
    if env_key <> "" then
        cfg.api_key = env_key;
    end
endfunction


function clean_msg = ee_sanitize_error(err_raw, api_key)
    // Sanitizes error messages by masking API keys and secret tokens
    // before displaying in GUI controls, logs, or exported reports.
    if typeof(err_raw) <> "string" then
        clean_msg = string(err_raw);
    else
        clean_msg = strcat(err_raw, " ");
    end
    clean_msg = stripblanks(clean_msg);

    // Mask query params
    try
        clean_msg = strsubst(clean_msg, "/key=[^& \t\r\n]+/", "key=***MASKED***", "r");
        clean_msg = strsubst(clean_msg, "/api_key=[^& \t\r\n]+/", "api_key=***MASKED***", "r");
        clean_msg = strsubst(clean_msg, "/Bearer [^& \t\r\n]+/", "Bearer ***MASKED***", "r");
    catch
        // In case regex throws
    end

    // Strip raw key string if provided and nontrivial
    if argn(2) >= 2 & typeof(api_key) == "string" then
        key_trimmed = stripblanks(api_key);
        if length(key_trimmed) >= 4 & key_trimmed <> "demo" then
            clean_msg = strsubst(clean_msg, key_trimmed, "***MASKED_API_KEY***");
        end
    end
endfunction


// ---------------------------------------------------------------------------
// 3. Structured Quantitative Snapshot Builder
// ---------------------------------------------------------------------------

function s = ee_fmt_num(val, dec)
    if argn(2) < 2 then dec = 2; end
    if isnan(val) then s = "n/a"; return; end
    if isinf(val) then
        if val > 0 then s = "+Inf"; else s = "-Inf"; end
        return;
    end
    s = msprintf("%." + string(dec) + "f", val);
endfunction


function s = ee_fmt_pct(val, dec)
    if argn(2) < 2 then dec = 2; end
    if isnan(val) then s = "n/a"; return; end
    if val >= 0 then
        s = "+" + msprintf("%." + string(dec) + "f%%", val);
    else
        s = msprintf("%." + string(dec) + "f%%", val);
    end
endfunction


function snap = ee_build_snapshot(data, analysis_res, naive_res, cmp_res, wf_res, bt_res, app_params)
    // Extracts and normalizes an immutable, evidence-grounded snapshot of already-computed
    // StockVision metrics and forecasts. Never alters underlying numbers.
    snap = struct();

    // 1. Asset & Provenance Metadata
    snap.has_data = (typeof(data) == "st" && isfield(data, "close") && size(data.close, "*") > 0);
    if snap.has_data then
        if isfield(data, "symbol") then snap.symbol = data.symbol; else snap.symbol = "UNKNOWN"; end
        if isfield(data, "exchange") then snap.exchange = data.exchange; else snap.exchange = "AUTO"; end
        if isfield(data, "currency") then snap.currency = data.currency; else snap.currency = "USD"; end
        if isfield(data, "provider") then snap.provider = data.provider; else snap.provider = "Synthetic"; end
        if isfield(data, "data_freshness") then snap.freshness = data.data_freshness; else snap.freshness = "Bundled Dataset"; end
        if isfield(data, "retrieval_time") then snap.retrieval_time = data.retrieval_time; else snap.retrieval_time = "N/A"; end
        if isfield(data, "cache_access_time") then snap.cache_access_time = data.cache_access_time; else snap.cache_access_time = "N/A"; end
        snap.is_cache_hit = (strindex(snap.freshness, "Local Cache Hit") <> []);
        snap.total_bars = data.n;
        snap.date_first = data.dates(1);
        snap.date_last = data.dates($);
        snap.last_close = data.close($);
        if snap.last_close >= 2.0 then
            snap.last_return_1d = (data.close($) - data.close($-1)) / data.close($-1) * 100.0;
        else
            snap.last_return_1d = 0.0;
        end
        snap.anomalies_detected = 0;
        if isfield(data, "quality") && typeof(data.quality) == "st" then
            if isfield(data.quality, "anomalies_detected") then snap.anomalies_detected = data.quality.anomalies_detected; end
            if isfield(data.quality, "price_jumps") then snap.price_jumps = data.quality.price_jumps; else snap.price_jumps = 0; end
            if isfield(data.quality, "zero_volume_bars") then snap.zero_volume_bars = data.quality.zero_volume_bars; else snap.zero_volume_bars = 0; end
            if isfield(data.quality, "date_gaps") then snap.date_gaps = data.quality.date_gaps; else snap.date_gaps = 0; end
            if isfield(data.quality, "dropped") then snap.dropped_rows = data.quality.dropped; else snap.dropped_rows = 0; end
        else
            snap.price_jumps = 0; snap.zero_volume_bars = 0; snap.date_gaps = 0; snap.dropped_rows = 0;
        end
    else
        snap.symbol = "NONE"; snap.exchange = ""; snap.currency = ""; snap.provider = "";
        snap.freshness = ""; snap.retrieval_time = ""; snap.cache_access_time = "";
        snap.is_cache_hit = %f; snap.total_bars = 0; snap.date_first = ""; snap.date_last = "";
        snap.last_close = %nan; snap.last_return_1d = %nan; snap.anomalies_detected = 0;
        snap.price_jumps = 0; snap.zero_volume_bars = 0; snap.date_gaps = 0; snap.dropped_rows = 0;
    end

    // Fixed Horizon Invariant
    snap.forecast_horizon = "1 trading day (next close)";

    // 2. Active Model Analysis
    snap.has_analysis = (typeof(analysis_res) == "st" && isfield(analysis_res, "next_price"));
    if snap.has_analysis then
        snap.active_model_name = analysis_res.name;
        snap.active_model_type = analysis_res.model_type;
        snap.active_next_price = analysis_res.next_price;
        if snap.has_data & snap.last_close > 0 then
            snap.active_pct_change = (analysis_res.next_price - snap.last_close) / snap.last_close * 100.0;
        else
            snap.active_pct_change = %nan;
        end
        // Signal logic
        buy_thr = 0.5; sell_thr = -0.5;
        if argn(2) >= 7 & typeof(app_params) == "st" then
            if isfield(app_params, "buy") then buy_thr = app_params.buy; end
            if isfield(app_params, "sell") then sell_thr = app_params.sell; end
        end
        snap.buy_threshold = buy_thr;
        snap.sell_threshold = sell_thr;
        if snap.active_pct_change >= buy_thr then
            snap.active_signal = "BUY";
        elseif snap.active_pct_change <= sell_thr then
            snap.active_signal = "SELL";
        else
            snap.active_signal = "HOLD";
        end

        // Prediction intervals
        snap.active_ci_lo = analysis_res.ci_lo;
        snap.active_ci_hi = analysis_res.ci_hi;
        snap.has_valid_ci = (~isnan(snap.active_ci_lo) & ~isnan(snap.active_ci_hi) & ..
                             ~isinf(snap.active_ci_lo) & ~isinf(snap.active_ci_hi) & ..
                             snap.active_ci_lo > 0 & snap.active_ci_hi > snap.active_ci_lo);
        if snap.has_valid_ci then
            snap.active_ci_width = snap.active_ci_hi - snap.active_ci_lo;
            if snap.last_close > 0 then
                snap.active_ci_width_pct = snap.active_ci_width / snap.last_close * 100.0;
            else
                snap.active_ci_width_pct = %nan;
            end
        else
            snap.active_ci_width = %nan;
            snap.active_ci_width_pct = %nan;
        end

        // Validation metrics
        m = analysis_res.metrics;
        snap.test_rmse = m.rmse;
        snap.test_mae = m.mae;
        snap.test_mape = m.mape;
        snap.test_r2 = m.r2;
        snap.dir_acc = m.dir_acc;
        if isfield(m, "theil_u") then snap.theil_u = m.theil_u; else snap.theil_u = %nan; end
        if isfield(m, "theil_u2_vs_naive") then snap.theil_u2_vs_naive = m.theil_u2_vs_naive; else snap.theil_u2_vs_naive = %nan; end
        if isfield(analysis_res, "split_cal") then
            snap.train_rows = analysis_res.split_cal;
        elseif isfield(analysis_res, "n_train") then
            snap.train_rows = analysis_res.n_train;
        else
            snap.train_rows = 0;
        end
        if isfield(analysis_res, "n_test") then
            snap.test_rows = analysis_res.n_test;
        elseif isfield(analysis_res, "y_pred") then
            snap.test_rows = size(analysis_res.y_pred, "*");
        else
            snap.test_rows = 0;
        end
    else
        snap.active_model_name = "None"; snap.active_model_type = "";
        snap.active_next_price = %nan; snap.active_pct_change = %nan;
        snap.active_signal = "NONE"; snap.buy_threshold = 0.5; snap.sell_threshold = -0.5;
        snap.active_ci_lo = %nan; snap.active_ci_hi = %nan; snap.has_valid_ci = %f;
        snap.active_ci_width = %nan; snap.active_ci_width_pct = %nan;
        snap.test_rmse = %nan; snap.test_mae = %nan; snap.test_mape = %nan;
        snap.test_r2 = %nan; snap.dir_acc = %nan; snap.theil_u = %nan;
        snap.theil_u2_vs_naive = %nan; snap.train_rows = 0; snap.test_rows = 0;
    end

    // 3. Naive Baseline
    snap.has_naive = (typeof(naive_res) == "st" && isfield(naive_res, "next_price"));
    if snap.has_naive then
        snap.naive_next_price = naive_res.next_price;
        snap.naive_test_rmse = naive_res.metrics.rmse;
        snap.naive_test_mae = naive_res.metrics.mae;
    else
        snap.naive_next_price = %nan;
        snap.naive_test_rmse = %nan;
        snap.naive_test_mae = %nan;
    end

    // 4. Multi-Model Comparison & Disagreement
    snap.has_comparison = (typeof(cmp_res) == "st" && isfield(cmp_res, "results") && size(cmp_res.results) > 0);
    if snap.has_comparison then
        snap.n_models = size(cmp_res.labels, 1);
        snap.model_labels = cmp_res.labels;
        snap.model_keys = cmp_res.keys;
        f_vec = zeros(snap.n_models, 1) * %nan;
        rmse_vec = zeros(snap.n_models, 1) * %nan;
        mae_vec = zeros(snap.n_models, 1) * %nan;
        r2_vec = zeros(snap.n_models, 1) * %nan;
        dir_vec = zeros(snap.n_models, 1) * %nan;
        u2_vec = zeros(snap.n_models, 1) * %nan;
        wf_rmse_vec = zeros(snap.n_models, 1) * %nan;
        sigs = repmat("", snap.n_models, 1);

        for i = 1:snap.n_models
            r_item = cmp_res.results(i);
            f_vec(i) = r_item.next_price;
            m_item = r_item.metrics;
            rmse_vec(i) = m_item.rmse;
            mae_vec(i) = m_item.mae;
            r2_vec(i) = m_item.r2;
            dir_vec(i) = m_item.dir_acc;
            if isfield(m_item, "theil_u2_vs_naive") then u2_vec(i) = m_item.theil_u2_vs_naive; end
            if isfield(cmp_res, "M") & size(cmp_res.M, 2) >= 6 then
                wf_rmse_vec(i) = cmp_res.M(i, 6);
            end
            if snap.has_data & snap.last_close > 0 then
                chg = (r_item.next_price - snap.last_close) / snap.last_close * 100.0;
                if chg >= snap.buy_threshold then sigs(i) = "BUY";
                elseif chg <= snap.sell_threshold then sigs(i) = "SELL";
                else sigs(i) = "HOLD"; end
            end
        end

        snap.cmp_forecasts = f_vec;
        snap.cmp_rmses = rmse_vec;
        snap.cmp_maes = mae_vec;
        snap.cmp_r2s = r2_vec;
        snap.cmp_dir_accs = dir_vec;
        snap.cmp_u2s = u2_vec;
        snap.cmp_wf_rmses = wf_rmse_vec;
        snap.cmp_signals = sigs;

        // Disagreement calculations across candidate models (ignoring Naive baseline if desired, or all)
        valid_f = f_vec(~isnan(f_vec));
        if size(valid_f, "*") >= 2 then
            snap.min_forecast = min(valid_f);
            snap.max_forecast = max(valid_f);
            snap.mean_forecast = mean(valid_f);
            snap.spread_abs = snap.max_forecast - snap.min_forecast;
            if snap.mean_forecast > 0 then
                snap.spread_pct = (snap.spread_abs / snap.mean_forecast) * 100.0;
            else
                snap.spread_pct = 0.0;
            end
            snap.std_forecast = stdev(valid_f);

            // Consensus direction relative to current close
            n_up = 0; n_down = 0; n_flat = 0;
            for i = 1:size(valid_f, "*")
                if valid_f(i) > snap.last_close + 1e-4 then n_up = n_up + 1;
                elseif valid_f(i) < snap.last_close - 1e-4 then n_down = n_down + 1;
                else n_flat = n_flat + 1; end
            end
            snap.n_models_up = n_up;
            snap.n_models_down = n_down;
            snap.n_models_flat = n_flat;
            tot = size(valid_f, "*");
            if n_up == tot then
                snap.directional_consensus = "Strong Bullish Consensus (" + string(n_up) + "/" + string(tot) + " UP)";
            elseif n_down == tot then
                snap.directional_consensus = "Strong Bearish Consensus (" + string(n_down) + "/" + string(tot) + " DOWN)";
            elseif n_up > n_down & n_up >= round(tot / 2) then
                snap.directional_consensus = "Moderate Bullish Lean (" + string(n_up) + "/" + string(tot) + " UP)";
            elseif n_down > n_up & n_down >= round(tot / 2) then
                snap.directional_consensus = "Moderate Bearish Lean (" + string(n_down) + "/" + string(tot) + " DOWN)";
            else
                snap.directional_consensus = "Divergent / Split Consensus (" + string(n_up) + " UP, " + string(n_down) + " DOWN, " + string(n_flat) + " FLAT)";
            end
        else
            snap.min_forecast = %nan; snap.max_forecast = %nan; snap.mean_forecast = %nan;
            snap.spread_abs = 0.0; snap.spread_pct = 0.0; snap.std_forecast = 0.0;
            snap.n_models_up = 0; snap.n_models_down = 0; snap.n_models_flat = 0;
            snap.directional_consensus = "Single model only (no comparison spread)";
        end

        // Ranking details
        if isfield(cmp_res, "rank") && typeof(cmp_res.rank) == "st" then
            rk = cmp_res.rank;
            snap.best_model_idx = rk.best_idx;
            if rk.best_idx > 0 & rk.best_idx <= snap.n_models then
                snap.best_model_label = snap.model_labels(rk.best_idx);
                snap.best_model_rmse = snap.cmp_rmses(rk.best_idx);
            else
                snap.best_model_label = "None";
                snap.best_model_rmse = %nan;
            end
            // Check if naive baseline outperformed candidate models
            if rk.naive_rank_pos == 1 then
                snap.naive_beats_all = %t;
            else
                snap.naive_beats_all = %f;
            end
            snap.model_order = rk.order;
        else
            snap.best_model_idx = 0; snap.best_model_label = "None"; snap.best_model_rmse = %nan;
            snap.naive_beats_all = %f; snap.model_order = [];
        end
    else
        snap.n_models = 0; snap.model_labels = []; snap.model_keys = [];
        snap.cmp_forecasts = []; snap.cmp_rmses = []; snap.cmp_maes = [];
        snap.cmp_r2s = []; snap.cmp_dir_accs = []; snap.cmp_u2s = [];
        snap.cmp_wf_rmses = []; snap.cmp_signals = [];
        snap.min_forecast = %nan; snap.max_forecast = %nan; snap.mean_forecast = %nan;
        snap.spread_abs = 0.0; snap.spread_pct = 0.0; snap.std_forecast = 0.0;
        snap.n_models_up = 0; snap.n_models_down = 0; snap.n_models_flat = 0;
        snap.directional_consensus = "Not evaluated yet";
        snap.best_model_idx = 0; snap.best_model_label = "None"; snap.best_model_rmse = %nan;
        snap.naive_beats_all = %f; snap.model_order = [];
    end

    // 5. Walk-Forward Cross-Validation
    snap.has_wf = (typeof(wf_res) == "st" && isfield(wf_res, "mean_rmse"));
    if snap.has_wf then
        if isfield(wf_res, "n_used") then
            snap.wf_k = wf_res.n_used;
        elseif isfield(wf_res, "k") then
            snap.wf_k = wf_res.k;
        else
            snap.wf_k = 0;
        end
        snap.wf_mean_rmse = wf_res.mean_rmse;
        if isfield(wf_res, "std_rmse") then snap.wf_std_rmse = wf_res.std_rmse; else snap.wf_std_rmse = zeros(wf_res.mean_rmse); end
    else
        snap.wf_k = 0; snap.wf_mean_rmse = []; snap.wf_std_rmse = [];
    end

    // 6. Backtest Simulation
    snap.has_bt = (typeof(bt_res) == "st" && isfield(bt_res, "strategy_return_pct"));
    if snap.has_bt then
        if isfield(bt_res, "starting_capital") then snap.initial_capital = bt_res.starting_capital;
        elseif isfield(bt_res, "initial_capital") then snap.initial_capital = bt_res.initial_capital;
        else snap.initial_capital = 100000; end

        if isfield(bt_res, "strategy_final") then snap.ending_capital = bt_res.strategy_final;
        elseif isfield(bt_res, "ending_capital") then snap.ending_capital = bt_res.ending_capital;
        else snap.ending_capital = %nan; end

        snap.strategy_return_pct = bt_res.strategy_return_pct;
        if isfield(bt_res, "buyhold_return_pct") then snap.buy_hold_return_pct = bt_res.buyhold_return_pct;
        elseif isfield(bt_res, "buy_hold_return_pct") then snap.buy_hold_return_pct = bt_res.buy_hold_return_pct;
        else snap.buy_hold_return_pct = %nan; end
        snap.excess_return_pct = snap.strategy_return_pct - snap.buy_hold_return_pct;

        if isfield(bt_res, "n_trades") then snap.total_trades = bt_res.n_trades;
        elseif isfield(bt_res, "total_trades") then snap.total_trades = bt_res.total_trades;
        else snap.total_trades = 0; end

        if isfield(bt_res, "win_rate_pct") then snap.win_rate_pct = bt_res.win_rate_pct; else snap.win_rate_pct = %nan; end
        if isfield(bt_res, "max_drawdown_pct") then snap.max_drawdown_pct = bt_res.max_drawdown_pct; else snap.max_drawdown_pct = %nan; end
        if isfield(bt_res, "sharpe_ratio") then snap.sharpe_ratio = bt_res.sharpe_ratio; else snap.sharpe_ratio = %nan; end
        if isfield(bt_res, "calmar_ratio") then snap.calmar_ratio = bt_res.calmar_ratio; else snap.calmar_ratio = %nan; end
        if isfield(bt_res, "profit_factor") then snap.profit_factor = bt_res.profit_factor; else snap.profit_factor = %nan; end
        if isfield(bt_res, "total_costs_paid") then snap.total_costs_paid = bt_res.total_costs_paid; else snap.total_costs_paid = %nan; end
        if isfield(bt_res, "transaction_cost_pct") then snap.transaction_cost_pct = bt_res.transaction_cost_pct; else snap.transaction_cost_pct = 0.1; end
        if isfield(bt_res, "slippage_pct") then snap.slippage_pct = bt_res.slippage_pct; else snap.slippage_pct = 0.05; end
    else
        snap.initial_capital = %nan; snap.ending_capital = %nan;
        snap.strategy_return_pct = %nan; snap.buy_hold_return_pct = %nan;
        snap.excess_return_pct = %nan; snap.total_trades = 0; snap.win_rate_pct = %nan;
        snap.max_drawdown_pct = %nan; snap.sharpe_ratio = %nan; snap.calmar_ratio = %nan;
        snap.profit_factor = %nan; snap.total_costs_paid = %nan;
        snap.transaction_cost_pct = %nan; snap.slippage_pct = %nan;
    end
endfunction


// ---------------------------------------------------------------------------
// 4. Mode A: Deterministic Offline Explanation Engine (Required)
// ---------------------------------------------------------------------------

function lines = ee_generate_offline_explanation(snap)
    // Generates a complete, evidence-grounded, multi-section quantitative briefing
    // from the snapshot without requiring an internet connection or external API.
    // 100% deterministic, reproducible, and mathematically factual.

    lines = [ ..
        "================================================================================"; ..
        "  STOCKVISION FORECAST INTELLIGENCE & EXPLANATION BRIEFING"; ..
        "  Mode: Deterministic Offline Quantitative Intelligence Layer"; ..
        "================================================================================"; ..
        ""];

    if ~snap.has_data then
        lines = [lines; ..
            "STATUS: NO DATASET LOADED"; ..
            "  Please select a bundled dataset or fetch market data to initiate analysis."; ..
            "================================================================================"];
        return;
    end

    if ~snap.has_analysis then
        lines = [lines; ..
            "STATUS: DATA LOADED, NO MODEL ANALYSIS EXECUTED"; ..
            "  Asset: " + snap.symbol + " (" + snap.exchange + ", " + snap.currency + ")"; ..
            "  Observations: " + string(snap.total_bars) + " bars spanning [" + snap.date_first + " to " + snap.date_last + "]"; ..
            "  Last Close:   " + ee_fmt_num(snap.last_close, 2) + " " + snap.currency; ..
            ""; ..
            "  Action Required: Click [Run Analysis] to fit the selected model and evaluate"; ..
            "  out-of-sample forecast accuracy."; ..
            "================================================================================"];
        return;
    end

    // -----------------------------------------------------------------------
    // SECTION 1: Executive Forecast Summary
    // -----------------------------------------------------------------------
    lines = [lines; ..
        "--- 1. EXECUTIVE FORECAST SUMMARY ---"; ..
        "  Target Asset:     " + snap.symbol + " (" + snap.exchange + " | " + snap.currency + ")"; ..
        "  Forecast Horizon: " + snap.forecast_horizon; ..
        "  Current Price:    " + ee_fmt_num(snap.last_close, 2) + " " + snap.currency + " (Close on " + snap.date_last + ")"; ..
        "  Active Model:     " + snap.active_model_name; ..
        "  Point Forecast:   " + ee_fmt_num(snap.active_next_price, 2) + " " + snap.currency + " (" + ee_fmt_pct(snap.active_pct_change, 2) + " predicted change)"; ..
        "  Trading Signal:   " + snap.active_signal + " (Thresholds: BUY >= +" + ee_fmt_num(snap.buy_threshold, 2) + "%, SELL <= " + ee_fmt_num(snap.sell_threshold, 2) + "%)"];

    if snap.has_valid_ci then
        lines = [lines; ..
            "  95% Forecast Band:[" + ee_fmt_num(snap.active_ci_lo, 2) + " - " + ee_fmt_num(snap.active_ci_hi, 2) + "] " + snap.currency + ..
            " (Bandwidth: " + ee_fmt_num(snap.active_ci_width, 2) + " " + snap.currency + " / " + ee_fmt_pct(snap.active_ci_width_pct, 1) + ")"];
    else
        lines = [lines; ..
            "  95% Forecast Band: UNAVAILABLE or DEGENERATE (sample size or variance constraint)"];
    end

    // Core interpretation of point forecast
    if abs(snap.active_pct_change) < 0.1 then
        lines = [lines; ..
            "  Interpretation:   Model projects near-zero price movement. In accordance with"; ..
            "                    the efficient market hypothesis, expected return is indistinguishable"; ..
            "                    from random daily noise."];
    elseif snap.active_pct_change > 0 then
        lines = [lines; ..
            "  Interpretation:   Model identifies positive forward momentum of " + ee_fmt_pct(snap.active_pct_change, 2) + "."; ..
            "                    Confidence is bounded by the 95% interval width."];
    else
        lines = [lines; ..
            "  Interpretation:   Model projects downward price adjustment of " + ee_fmt_pct(snap.active_pct_change, 2) + "."; ..
            "                    Risk mitigation suggests defensive positioning or HOLD/SELL."];
    end
    lines = [lines; ""];

    // -----------------------------------------------------------------------
    // SECTION 2: Multi-Model Comparison & Disagreement Analysis
    // -----------------------------------------------------------------------
    lines = [lines; ..
        "--- 2. MULTI-MODEL FORECAST COMPARISON & DISAGREEMENT ---"];
    if snap.has_comparison then
        lines = [lines; ..
            "  Consensus Outlook:" + snap.directional_consensus; ..
            "  Spread Across Models: " + ee_fmt_num(snap.spread_abs, 2) + " " + snap.currency + " (" + ee_fmt_num(snap.spread_pct, 2) + "% of mean forecast)"; ..
            "  Forecast Range:   [" + ee_fmt_num(snap.min_forecast, 2) + " - " + ee_fmt_num(snap.max_forecast, 2) + "] " + snap.currency; ..
            "  Model Standard Dev: " + ee_fmt_num(snap.std_forecast, 3) + " " + snap.currency; ..
            ""; ..
            "  Model Breakdown (Sorted by Test RMSE):"; ..
            "  " + part("Model", 1:16) + part("Forecast", 1:12) + part("Change", 1:10) + part("Signal", 1:8) + part("Test RMSE", 1:12) + part("Theil U2", 1:10)];

        for a = 1:size(snap.model_order, "*")
            idx = snap.model_order(a);
            lbl = snap.model_labels(idx);
            fc = ee_fmt_num(snap.cmp_forecasts(idx), 2);
            chg = ee_fmt_pct((snap.cmp_forecasts(idx) - snap.last_close) / snap.last_close * 100.0, 2);
            sig = snap.cmp_signals(idx);
            rm = ee_fmt_num(snap.cmp_rmses(idx), 3);
            u2 = ee_fmt_num(snap.cmp_u2s(idx), 3);
            lines = [lines; "  " + part(lbl, 1:16) + part(fc, 1:12) + part(chg, 1:10) + part(sig, 1:8) + part(rm, 1:12) + part(u2, 1:10)];
        end

        lines = [lines; ""];
        if snap.spread_pct > 2.0 then
            lines = [lines; ..
                "  Disagreement Warning: Model spread exceeds 2.0%. Structural divergence"; ..
                "  indicates that linear autoregression, exponential smoothing, and regression"; ..
                "  differ on current market regime. Rely on walk-forward rankings rather than"; ..
                "  any single model."];
        else
            lines = [lines; ..
                "  Disagreement Note: Models exhibit tight convergence (< 2.0% spread)."; ..
                "  Forecast estimates reflect high structural consensus."];
        end
    else
        lines = [lines; ..
            "  Multi-model comparison not executed yet."; ..
            "  Tip: Click [Compare Models] to compute simultaneous forecasts, disagreement"; ..
            "  spreads, and ranking across Naive, LR, AR, ES, and Ridge."];
    end
    lines = [lines; ""];

    // -----------------------------------------------------------------------
    // SECTION 3: Empirical Validation & Theil U Interpretation
    // -----------------------------------------------------------------------
    lines = [lines; ..
        "--- 3. EMPIRICAL VALIDATION & BENCHMARK EVALUATION ---"; ..
        "  Evaluation Protocol: Chronological split (" + string(snap.train_rows) + " train / " + string(snap.test_rows) + " test observations, strictly un-shuffled)"; ..
        "  Active Model Test RMSE: " + ee_fmt_num(snap.test_rmse, 3) + " " + snap.currency; ..
        "  Active Model Test MAE:  " + ee_fmt_num(snap.test_mae, 3) + " " + snap.currency; ..
        "  Directional Accuracy:   " + ee_fmt_num(snap.dir_acc, 1) + "%"; ..
        "  Theil U1 (Inequality):  " + ee_fmt_num(snap.theil_u, 4) + " (0 = perfect, 1 = maximum inequality)"];

    if ~isnan(snap.theil_u2_vs_naive) then
        lines = [lines; ..
            "  Theil U2 (vs Naive):    " + ee_fmt_num(snap.theil_u2_vs_naive, 4)];
        if snap.theil_u2_vs_naive < 0.98 then
            imprv = (1.0 - snap.theil_u2_vs_naive) * 100.0;
            lines = [lines; ..
                "  Theil U2 Meaning:    U2 < 1.0 indicates genuine predictive skill. The active model"; ..
                "                       achieves a " + ee_fmt_num(imprv, 1) + "% RMSE reduction relative to the random-walk"; ..
                "                       naive persistence baseline (y_{t+1} = y_t)."];
        elseif snap.theil_u2_vs_naive > 1.02 then
            worse = (snap.theil_u2_vs_naive - 1.0) * 100.0;
            lines = [lines; ..
                "  Theil U2 Meaning:    U2 > 1.0 indicates underperformance. The active model has " + ee_fmt_num(worse, 1) + "%"; ..
                "                       higher out-of-sample error than simply guessing yesterday closing price."; ..
                "                       On this asset, the market behaves as a persistent random walk."];
        else
            lines = [lines; ..
                "  Theil U2 Meaning:    U2 ~ 1.0 indicates parity with random walk. The active model"; ..
                "                       neither beats nor substantially underperforms naive persistence."];
        end
    end

    if snap.has_comparison & snap.naive_beats_all then
        lines = [lines; ..
            "  CRITICAL BENCHMARK FINDING: Naive persistence (last closing price) ranked #1"; ..
            "  among all models on the validation window. This is common in efficient or"; ..
            "  highly liquid equities. Do NOT place high confidence in statistical extrapolations."];
    end
    lines = [lines; ""];

    // -----------------------------------------------------------------------
    // SECTION 4: Prediction Intervals & Uncertainty Calibration
    // -----------------------------------------------------------------------
    lines = [lines; ..
        "--- 4. UNCERTAINTY & RISK ASSESSMENT ---"];
    if snap.has_valid_ci then
        lines = [lines; ..
            "  Interval Coverage:  95% nominal confidence level."; ..
            "  Lower Bound:        " + ee_fmt_num(snap.active_ci_lo, 2) + " " + snap.currency + " (" + ee_fmt_pct((snap.active_ci_lo - snap.last_close) / snap.last_close * 100.0, 2) + ")"; ..
            "  Upper Bound:        " + ee_fmt_num(snap.active_ci_hi, 2) + " " + snap.currency + " (" + ee_fmt_pct((snap.active_ci_hi - snap.last_close) / snap.last_close * 100.0, 2) + ")"; ..
            "  Total Uncertainty:  " + ee_fmt_num(snap.active_ci_width, 2) + " " + snap.currency + " (" + ee_fmt_num(snap.active_ci_width_pct, 1) + "% of current price)"; ..
            ""; ..
            "  Calibration Context:The interval represents parameter estimation uncertainty combined"; ..
            "                      with residual standard error. Under Gaussian assumptions, 95 out of"; ..
            "                      100 tomorrow closes fall within this envelope. High interval width"; ..
            "                      implies elevated market volatility or weak feature correlation."];
    else
        lines = [lines; ..
            "  Interval Status:    Valid prediction interval cannot be calibrated."; ..
            "  Reason:             Insufficient degrees of freedom, constant price series, or singular matrix."];
    end
    lines = [lines; ""];

    // -----------------------------------------------------------------------
    // SECTION 5: Data Quality, Provenance & Freshness
    // -----------------------------------------------------------------------
    lines = [lines; ..
        "--- 5. DATA QUALITY & PROVENANCE ASSESSMENT ---"; ..
        "  Data Source:        " + snap.provider; ..
        "  Data Freshness:     " + snap.freshness; ..
        "  Retrieval Time:     " + snap.retrieval_time; ..
        "  Total Usable Bars:  " + string(snap.total_bars) + " trading days"];

    if snap.total_bars < 30 then
        lines = [lines; ..
            "  WARNING: CRITICAL SAMPLE SIZE DEFICIT (" + string(snap.total_bars) + " < 30 bars). Statistical models"; ..
            "           suffer from severe small-sample variance. Validation metrics are unstable."];
    elseif snap.total_bars < 60 then
        lines = [lines; ..
            "  NOTE: LIMITED SAMPLE SIZE (" + string(snap.total_bars) + " bars). Walk-forward fold count is restricted."];
    else
        lines = [lines; ..
            "  Sample Adequacy:    Adequate statistical history (" + string(snap.total_bars) + " >= 60 bars)."];
    end

    if snap.anomalies_detected > 0 then
        lines = [lines; ..
            "  Anomaly Summary:    " + string(snap.anomalies_detected) + " data irregularities flagged:"; ..
            "                      " + string(snap.price_jumps) + " return jump(s) >50%, " + string(snap.zero_volume_bars) + ..
            " zero-volume bar(s), " + string(snap.date_gaps) + " trading calendar gap(s)."];
    else
        lines = [lines; ..
            "  Anomaly Summary:    Clean data feed (0 return jumps >50%, 0 zero-volume bars, 0 date gaps)."];
    end
    lines = [lines; ""];

    // -----------------------------------------------------------------------
    // SECTION 6: Methodological Limitations & Regulatory Disclaimers
    // -----------------------------------------------------------------------
    lines = [lines; ..
        "--- 6. METHODOLOGICAL WARNINGS & LIMITATIONS ---"; ..
        "  1. NO GUARANTEED RETURNS: Past statistical outperformance or backtest profit does"; ..
        "     NOT imply or guarantee future profitability. Market regimes change abruptly."; ..
        "  2. STATIONARITY ASSUMPTION: Models assume local stability of statistical moments."; ..
        "     Earnings announcements, macro interest rate shocks, and geopolitical events"; ..
        "     violate linear stationarity."; ..
        "  3. COST REALISM: Modeled backtests assume " + ee_fmt_num(snap.transaction_cost_pct, 2) + "% fee + " + ..
        ee_fmt_num(snap.slippage_pct, 2) + "% slippage. Illiquid stocks may experience higher drag."; ..
        "  4. EXOGENOUS INFORMATION: These statistical models do NOT incorporate corporate"; ..
        "     fundamentals, news sentiment, order book depth, or regulatory filings."];
    lines = [lines; ""];

    // -----------------------------------------------------------------------
    // SECTION 7: Suggested Analytical Follow-Up Actions
    // -----------------------------------------------------------------------
    lines = [lines; ..
        "--- 7. SUGGESTED ANALYTICAL ACTIONS ---"; ..
        "  - If Theil U2 > 1.0: Switch to Ridge Regression (L2) to prevent collinear overfitting,"; ..
        "    or adopt a conservative HOLD strategy."; ..
        "  - If Disagreement Spread > 2%: Run 5-fold Walk-Forward Validation to observe which"; ..
        "    model exhibited the lowest variance across changing market regimes."; ..
        "  - Sensitivity Test: Adjust the Train/Test slider to 70% or 85% to test whether"; ..
        "    model rankings are robust to sample window boundaries."];

    lines = [lines; ..
        "================================================================================"];
endfunction


// ---------------------------------------------------------------------------
// 5. Prompt Construction for Evidence-Grounded AI (Mode B)
// ---------------------------------------------------------------------------

function prompt = ee_build_grounding_prompt(snap)
    // Converts the quantitative snapshot into an evidence-grounded prompt
    // that forbids hallucination and constrains the LLM to supplied facts only.
    p = [ ..
        "You are the StockVision quantitative explanation assistant. Explain the following computed statistical forecast snapshot."; ..
        "CRITICAL CONSTRAINTS & GROUNDING RULES:"; ..
        "1. Use ONLY the facts and computed metrics provided in the JSON snapshot below."; ..
        "2. Do NOT invent stock prices, corporate news, dates, historical events, or financial metrics."; ..
        "3. Explicitly state when a metric or prediction interval is missing or degenerate."; ..
        "4. NEVER promise or guarantee financial returns. Frame all forecasts strictly as statistical estimates."; ..
        "5. NEVER give direct investment or trading directives (e.g. do NOT say: You must buy this stock)."; ..
        "6. Emphasize that models are statistical approximations and past backtest performance does not guarantee future results."; ..
        ""; ..
        "FACTUAL COMPUTED SNAPSHOT:"; ..
        "Asset Symbol: " + snap.symbol; ..
        "Exchange: " + snap.exchange; ..
        "Currency: " + snap.currency; ..
        "Data Provider: " + snap.provider; ..
        "Data Freshness: " + snap.freshness; ..
        "Historical Bars: " + string(snap.total_bars); ..
        "Date Range: " + snap.date_first + " to " + snap.date_last; ..
        "Latest Observed Close: " + ee_fmt_num(snap.last_close, 2) + " " + snap.currency; ..
        "Forecast Horizon: " + snap.forecast_horizon; ..
        "Active Model: " + snap.active_model_name; ..
        "Active Model Forecast: " + ee_fmt_num(snap.active_next_price, 2) + " (" + ee_fmt_pct(snap.active_pct_change, 2) + ")"; ..
        "Active Model Signal: " + snap.active_signal; ..
        "Active Model 95% Band: [" + ee_fmt_num(snap.active_ci_lo, 2) + " - " + ee_fmt_num(snap.active_ci_hi, 2) + "] (Valid: " + string(snap.has_valid_ci) + ")"; ..
        "Active Model Test RMSE: " + ee_fmt_num(snap.test_rmse, 3); ..
        "Active Model Test MAE: " + ee_fmt_num(snap.test_mae, 3); ..
        "Active Model Theil U2 vs Naive: " + ee_fmt_num(snap.theil_u2_vs_naive, 4); ..
        "Directional Accuracy: " + ee_fmt_num(snap.dir_acc, 1) + "%"; ..
        "Consensus Outlook: " + snap.directional_consensus; ..
        "Model Disagreement Spread: " + ee_fmt_num(snap.spread_abs, 2) + " " + snap.currency + " (" + ee_fmt_num(snap.spread_pct, 2) + "%)"; ..
        "Naive Beats All Models: " + string(snap.naive_beats_all); ..
        "Data Anomalies Detected: " + string(snap.anomalies_detected); ..
        ""; ..
        "Please provide a structured, professional 5-paragraph briefing:"; ..
        "Paragraph 1: Executive Forecast & Horizon Summary"; ..
        "Paragraph 2: Model Disagreement & Consensus Spread"; ..
        "Paragraph 3: Validation & Theil U Interpretation"; ..
        "Paragraph 4: Uncertainty, Prediction Intervals & Data Quality"; ..
        "Paragraph 5: Methodological Warnings & Limitations (No Guarantees)"];

    prompt = strcat(p, ascii(10));
endfunction


// ---------------------------------------------------------------------------
// 6. Mode B: Optional AI-Generated Explanation (Google Gemini API)
// ---------------------------------------------------------------------------

function [lines, status_msg, used_mode] = ee_generate_ai_explanation(snap, cfg)
    // Generates an explanation using Google Gemini API when configured,
    // with strict JSON payload construction, key sanitization, and graceful
    // automatic fallback to Mode A if offline, keyless, rate-limited, or network fails.

    lines = [];
    status_msg = "";
    used_mode = "OFFLINE_DETERMINISTIC";

    // 1. Check if mock fixture is provided (for offline automated testing)
    if isfield(cfg, "mock_response_file") & cfg.mock_response_file <> "" then
        if isfile(cfg.mock_response_file) then
            try
                m_lines = mgetl(cfg.mock_response_file);
                m_raw = strcat(m_lines, "");
                m_json = fromJSON(m_raw);
                text_out = m_json.candidates(1).content.parts(1).text;
                // Parse lines
                text_lines = strsplit(text_out, ascii(10));
                lines = [ ..
                    "================================================================================"; ..
                    "  STOCKVISION FORECAST INTELLIGENCE & EXPLANATION BRIEFING"; ..
                    "  Mode: Evidence-Grounded AI Assistant (Google Gemini API — Mock Fixture)"; ..
                    "  Notice: Natural language briefing strictly grounded in Scilab quantitative output."; ..
                    "================================================================================"; ..
                    ""; ..
                    text_lines; ..
                    ""; ..
                    "================================================================================"];
                status_msg = "SUCCESS_AI_MOCK";
                used_mode = "AI_GEMINI_MOCK";
                return;
            catch
                // If mock fails to parse, proceed to fallback
            end
        end
    end

    // 2. Validate API key and configuration
    if cfg.api_key == "" | cfg.provider == "offline" then
        lines = ee_generate_offline_explanation(snap);
        status_msg = "OFFLINE_MODE (No AI API key configured)";
        used_mode = "OFFLINE_DETERMINISTIC";
        return;
    end

    // 3. Construct prompt
    prompt_text = ee_build_grounding_prompt(snap);

    // Build Gemini REST payload struct
    // Schema: { "contents": [{ "parts": [{"text": "..."}] }], "generationConfig": {...} }
    req_struct = struct();
    part_struct = struct("text", prompt_text);
    content_struct = struct("parts", list(part_struct));
    req_struct.contents = list(content_struct);
    req_struct.generationConfig = struct("temperature", cfg.temperature, "maxOutputTokens", cfg.max_output_tokens);

    json_payload = toJSON(req_struct);

    // Write payload to temporary file
    payload_file = TMPDIR + filesep() + "sv_ai_req.json";
    resp_file = TMPDIR + filesep() + "sv_ai_resp.txt";
    mputl(json_payload, payload_file);

    endpoint_url = cfg.base_url + "/" + cfg.model + ":generateContent?key=" + cfg.api_key;

    // Execute via curl.exe with timeout and status code output
    cmd = "curl.exe -s --max-time " + string(cfg.timeout_seconds) + ..
          " -X POST -H ""Content-Type: application/json""" + ..
          " --data-binary ""@" + payload_file + """" + ..
          " -w ""\n%{http_code}"" " + ..
          " """ + endpoint_url + """ > """ + resp_file + """";

    stat = host(cmd);

    // Evaluate response
    ai_success = %f;
    fail_reason = "";
    resp_text = "";

    if stat == 0 & isfile(resp_file) then
        try
            raw_lines = mgetl(resp_file);
            if size(raw_lines, "*") >= 2 then
                http_code = stripblanks(raw_lines($));
                body_lines = raw_lines(1:$-1);
                body_raw = strcat(body_lines, "");
                if http_code == "200" then
                    parsed_res = fromJSON(body_raw);
                    if isfield(parsed_res, "candidates") & size(parsed_res.candidates) > 0 then
                        cand0 = parsed_res.candidates(1);
                        if isfield(cand0, "content") & isfield(cand0.content, "parts") then
                            resp_text = cand0.content.parts(1).text;
                            if length(stripblanks(resp_text)) > 50 then
                                ai_success = %t;
                            end
                        end
                    end
                elseif http_code == "400" then
                    fail_reason = "HTTP 400 Bad Request (Malformed parameters or schema)";
                elseif http_code == "401" | http_code == "403" then
                    fail_reason = "HTTP 403 Forbidden (Invalid or unauthorized API key)";
                elseif http_code == "429" then
                    fail_reason = "HTTP 429 Rate Limit Exceeded (Google Gemini free tier quota reached)";
                elseif http_code == "500" | http_code == "503" then
                    fail_reason = "HTTP " + http_code + " Provider Service Unavailable";
                else
                    fail_reason = "HTTP " + http_code + " Unexpected Provider Response";
                end
            else
                fail_reason = "Empty or incomplete response payload";
            end
        catch
            parse_err = ee_sanitize_error(lasterror(), cfg.api_key);
            fail_reason = "JSON parsing failure: " + parse_err;
        end
    else
        fail_reason = "Network connection failed or timeout exceeded (" + string(cfg.timeout_seconds) + "s)";
    end

    // 4. On Success: Format and Return
    if ai_success then
        text_lines = strsplit(resp_text, ascii(10));
        lines = [ ..
            "================================================================================"; ..
            "  STOCKVISION FORECAST INTELLIGENCE & EXPLANATION BRIEFING"; ..
            "  Mode: Evidence-Grounded AI Assistant (Google Gemini: " + cfg.model + ")"; ..
            "  Notice: Natural language briefing strictly grounded in Scilab quantitative output."; ..
            "          Does not constitute financial or investment advice."; ..
            "================================================================================"; ..
            ""; ..
            text_lines; ..
            ""; ..
            "================================================================================"];
        status_msg = "SUCCESS_AI (" + cfg.model + ")";
        used_mode = "AI_GEMINI_LIVE";
        return;
    end

    // 5. On Failure: Graceful Fallback to Mode A
    clean_fail = ee_sanitize_error(fail_reason, cfg.api_key);
    lines = ee_generate_offline_explanation(snap);
    // Prepend diagnostic banner explaining fallback
    banner = [ ..
        "================================================================================"; ..
        "  [AI MODE DIAGNOSTIC NOTICE]"; ..
        "  External AI provider failed: " + clean_fail; ..
        "  -> Seamlessly reverted to Mode A (Deterministic Offline Quantitative Intelligence)."; ..
        "================================================================================"; ..
        ""];
    lines = [banner; lines];
    status_msg = "FALLBACK_OFFLINE: " + clean_fail;
    used_mode = "FALLBACK_TO_OFFLINE";
endfunction


// ---------------------------------------------------------------------------
// 7. Unified Primary Entry Point
// ---------------------------------------------------------------------------

function [lines, status_msg, used_mode] = ee_explain(data, analysis_res, naive_res, cmp_res, wf_res, bt_res, app_params, mode, config_override)
    // Primary entry point for generating forecast explanations in StockVision.
    //
    // Inputs:
    //   data, analysis_res, naive_res, cmp_res, wf_res, bt_res, app_params: StockVision engine structs
    //   mode: "offline" (default) or "ai"
    //   config_override: optional custom struct from ee_load_config()

    if argn(2) < 8 then mode = "offline"; end
    if argn(2) >= 9 & typeof(config_override) == "st" then
        cfg = config_override;
    else
        cfg = ee_load_config();
    end

    snap = ee_build_snapshot(data, analysis_res, naive_res, cmp_res, wf_res, bt_res, app_params);

    if convstr(stripblanks(mode), "l") == "ai" then
        [lines, status_msg, used_mode] = ee_generate_ai_explanation(snap, cfg);
    else
        lines = ee_generate_offline_explanation(snap);
        status_msg = "OFFLINE_DETERMINISTIC_SUCCESS";
        used_mode = "OFFLINE_DETERMINISTIC";
    end
endfunction
