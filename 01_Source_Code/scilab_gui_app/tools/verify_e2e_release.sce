// ============================================================================
// verify_e2e_release.sce -- Full-System End-to-End Forensic Audit & Release Gate
// Executes the complete pipeline across synthetic, US, and Indian assets,
// testing all 5 models, comparison, walk-forward, backtesting, explanations,
// fallbacks, and exports.
// ============================================================================
clear; clc;
APP_DIR = get_absolute_file_path("verify_e2e_release.sce") + "../";
exec(APP_DIR + "model_engine.sce", -1);
exec(APP_DIR + "market_data_adapter.sce", -1);
exec(APP_DIR + "explanation_engine.sce", -1);

mprintf("\n======================================================================\n");
mprintf("  StockVision Phase 4: Full-System Forensic Audit & E2E Verification\n");
mprintf("======================================================================\n\n");

global audit_passed audit_failures audit_skipped;
audit_passed = 0;
audit_failures = 0;
audit_skipped = 0;

function audit_assert(cond, desc)
    global audit_passed audit_failures;
    if cond then
        mprintf("  [PASS] %s\n", desc);
        audit_passed = audit_passed + 1;
    else
        mprintf("  [FAIL] %s\n", desc);
        audit_failures = audit_failures + 1;
    end
endfunction

function audit_skip(desc, reason)
    global audit_skipped;
    mprintf("  [SKIP] %s (Reason: %s)\n", desc, reason);
    audit_skipped = audit_skipped + 1;
endfunction

// --- Subsystem 1: Offline Datasets ---
mprintf("--- Subsystem 1: Offline Dataset Ingestion ---\n");
d_tech = load_dataset(APP_DIR + "sample_data/tech_growth_stock.csv");
audit_assert(d_tech.n == 300, "Tech Growth dataset loaded exactly 300 bars");
d_blue = load_dataset(APP_DIR + "sample_data/blue_chip_stock.csv");
audit_assert(d_blue.n == 300, "Blue Chip dataset loaded exactly 300 bars");
d_vol = load_dataset(APP_DIR + "sample_data/volatile_stock.csv");
audit_assert(d_vol.n == 300, "Volatile Stock dataset loaded exactly 300 bars");

// --- Subsystem 2: Market Data Adapter (US & Indian Feeds) ---
mprintf("\n--- Subsystem 2: Market Data Normalization (US AAPL & Indian INFY) ---\n");
aapl_path = APP_DIR + "sample_data/mock_market_data/mock_twelvedata_aapl.json";
infy_path = APP_DIR + "sample_data/mock_market_data/mock_twelvedata_infy_nse.json";
d_aapl = mda_load_mock(aapl_path, "AAPL", "NASDAQ");
audit_assert(d_aapl.n == 65 & d_aapl.currency == "USD" & d_aapl.exchange == "NASDAQ", "AAPL: 65 bars, NASDAQ, USD normalized");
d_infy = mda_load_mock(infy_path, "INFY", "NSE");
audit_assert(d_infy.n == 65 & d_infy.currency == "INR" & d_infy.exchange == "NSE", "INFY: 65 bars, NSE, INR normalized");

// --- Subsystem 3: 5 Forecasting Models Execution & Forecast Intervals ---
mprintf("\n--- Subsystem 3: 5-Model Execution & Uncertainty Intervals ---\n");
cfg = struct("split_ratio", 0.8, "ar_lookback", 10, "es_alpha", 0.3, "es_beta", 0.1, "n_folds", 5, ..
             "buy", 0.5, "sell", -0.5, "cost", 0.1, "slip", 0.05, "capital", 100000);

model_keys = ["NAIVE", "LR", "AR", "ES", "RIDGE"];
model_names = ["Naive Persistence", "Linear Regression", "Autoregressive AR(10)", "Holt Exp Smoothing", "Ridge Regression (L2)"];

for m = 1:size(model_keys, 2)
    k = model_keys(m);
    r_tech = run_model(d_tech, k, round(d_tech.n * 0.8), cfg.ar_lookback, cfg.es_alpha, cfg.es_beta, 1.0);
    audit_assert(r_tech.next_price > 0, "Tech: " + model_names(m) + " produces positive forecast (" + string(r_tech.next_price) + ")");
    audit_assert(r_tech.ci_lo < r_tech.next_price & r_tech.ci_hi > r_tech.next_price, "Tech: " + model_names(m) + " forecast bounded inside interval [" + string(r_tech.ci_lo) + ", " + string(r_tech.ci_hi) + "]");
    audit_assert(r_tech.metrics.rmse > 0, "Tech: " + model_names(m) + " test RMSE is strictly positive (" + string(r_tech.metrics.rmse) + ")");
end

// --- Subsystem 4: Multi-Model Comparison & Benchmarks ---
mprintf("\n--- Subsystem 4: Multi-Model Comparison & Benchmark Dynamics ---\n");
// 1. Tech Growth
cmp_tech = compare_models(d_tech, 0.8, 10, 0.3, 0.1, 5, %t);
audit_assert(size(cmp_tech.results) == 5, "Tech Growth 5-model comparison evaluated all 5 models");
mprintf("    Tech Growth Test RMSE: Naive=%.4f, LR=%.4f, AR=%.4f, ES=%.4f, Ridge=%.4f\n", ..
        cmp_tech.results(1).metrics.rmse, cmp_tech.results(2).metrics.rmse, cmp_tech.results(3).metrics.rmse, ..
        cmp_tech.results(4).metrics.rmse, cmp_tech.results(5).metrics.rmse);

// 2. AAPL NASDAQ (Offline Mock Fixture Verification)
cmp_aapl = compare_models(d_aapl, 0.8, 10, 0.3, 0.1, 3, %t);
audit_assert(size(cmp_aapl.results) == 5, "AAPL 5-model comparison evaluated all 5 models on mock fixture");
mprintf("    AAPL (Mock Fixture) Test RMSE: Naive=%.4f, LR=%.4f, AR=%.4f, ES=%.4f, Ridge=%.4f\n", ..
        cmp_aapl.results(1).metrics.rmse, cmp_aapl.results(2).metrics.rmse, cmp_aapl.results(3).metrics.rmse, ..
        cmp_aapl.results(4).metrics.rmse, cmp_aapl.results(5).metrics.rmse);
// Forensic check: Confirm AR(10) fits the mock fixture's 5-day periodicity
r_aapl_ar = cmp_aapl.results(3);
audit_assert(r_aapl_ar.metrics.rmse < 0.05, "Forensic Audit: AR(10) fits mock 5-day delta periodicity with RMSE < 0.05 (" + string(r_aapl_ar.metrics.rmse) + ")");

// Real Market Data Verification (from local cache when available)
cache_env = getenv("STOCKVISION_NO_CACHE", "0");
cache_active = (cache_env <> "1" & cache_env <> "true");

real_aapl_cache = "";
if isfile(APP_DIR + "../../cache/market_data/AAPL_NASDAQ_120.json") then
    real_aapl_cache = APP_DIR + "../../cache/market_data/AAPL_NASDAQ_120.json";
elseif isfile(APP_DIR + "../cache/market_data/AAPL_NASDAQ_120.json") then
    real_aapl_cache = APP_DIR + "../cache/market_data/AAPL_NASDAQ_120.json";
end

if cache_active & real_aapl_cache <> "" then
    d_real_aapl = mda_load_mock(real_aapl_cache, "AAPL", "NASDAQ");
    cmp_real_aapl = compare_models(d_real_aapl, 0.8, 10, 0.3, 0.1, 5, %t);
    mprintf("    Real AAPL (120 bars) Test RMSE: Naive=%.4f, LR=%.4f, AR=%.4f, ES=%.4f, Ridge=%.4f\n", ..
            cmp_real_aapl.results(1).metrics.rmse, cmp_real_aapl.results(2).metrics.rmse, cmp_real_aapl.results(3).metrics.rmse, ..
            cmp_real_aapl.results(4).metrics.rmse, cmp_real_aapl.results(5).metrics.rmse);
    audit_assert(cmp_real_aapl.results(3).metrics.rmse > 3.0, "Real AAPL: AR(10) produces realistic market RMSE > 3.0 (" + string(cmp_real_aapl.results(3).metrics.rmse) + ")");
    audit_assert(cmp_real_aapl.results(1).metrics.rmse <= cmp_real_aapl.results(3).metrics.rmse, "Real AAPL: Naive random walk baseline beats unregularized AR(10)");
else
    skip_reason = "Private/local cached market data unavailable in clean release distribution";
    audit_skip("Real AAPL: AR(10) produces realistic market RMSE > 3.0", skip_reason);
    audit_skip("Real AAPL: Naive random walk baseline beats unregularized AR(10)", skip_reason);
end

// 3. INFY NSE
cmp_infy = compare_models(d_infy, 0.8, 10, 0.3, 0.1, 3, %t);
audit_assert(size(cmp_infy.results) == 5, "INFY 5-model comparison evaluated all 5 models on mock fixture");
mprintf("    INFY (Mock Fixture) Test RMSE: Naive=%.4f, LR=%.4f, AR=%.4f, ES=%.4f, Ridge=%.4f\n", ..
        cmp_infy.results(1).metrics.rmse, cmp_infy.results(2).metrics.rmse, cmp_infy.results(3).metrics.rmse, ..
        cmp_infy.results(4).metrics.rmse, cmp_infy.results(5).metrics.rmse);
r_infy_ridge = cmp_infy.results(5);
r_infy_naive = cmp_infy.results(1);
audit_assert(r_infy_naive.metrics.rmse <= r_infy_ridge.metrics.rmse, "INFY: Random walk regime confirmed on mock fixture (Naive RMSE " + string(r_infy_naive.metrics.rmse) + " <= Ridge RMSE " + string(r_infy_ridge.metrics.rmse) + ")");

// --- Subsystem 5: Walk-Forward Validation Consistency ---
mprintf("\n--- Subsystem 5: Walk-Forward Cross-Validation ---\n");
wf_tech = cmp_tech.wf;
audit_assert(wf_tech.n_used == 5, "Tech Growth executed exactly 5 walk-forward folds");
audit_assert(size(wf_tech.fold_rmse, 2) == 5, "Walk-forward matrix tracked all 5 models across folds");
audit_assert(and(wf_tech.mean_rmse > 0), "All 5 models have positive walk-forward mean RMSE");

// --- Subsystem 6: Backtest Simulation & Real Friction Modeling ---
mprintf("\n--- Subsystem 6: Backtesting Simulation (0.1%% Cost, 0.05%% Slippage) ---\n");
r_tech_lr = cmp_tech.results(2);
bt_tech = run_backtest(r_tech_lr.y_true, r_tech_lr.y_pred, cfg.buy, cfg.sell, cfg.capital, cfg.cost, cfg.slip);
audit_assert(bt_tech.strategy_final > 0, "Backtest ending equity is positive (" + string(bt_tech.strategy_final) + ")");
audit_assert(bt_tech.total_costs_paid > 0, "Friction deduction active: total costs paid = " + string(bt_tech.total_costs_paid));
audit_assert(bt_tech.buyhold_costs_paid == cfg.capital * (cfg.cost + cfg.slip) / 100, "Buy & Hold properly charged entry cost (150.00)");
audit_assert(bt_tech.exposure_pct > 0 & bt_tech.exposure_pct <= 100, "Market exposure percentage properly bounded (" + string(bt_tech.exposure_pct) + "%)");

// --- Subsystem 7: Explanation Engine (Mode A, Mode B, Fallback Paths) ---
mprintf("\n--- Subsystem 7: Explanation Engine Briefings & Fallback Resilience ---\n");
// Mode A: Offline deterministic
snap_tech = ee_build_snapshot(d_tech, r_tech_lr, cmp_tech.results(1), cmp_tech, cmp_tech.wf, bt_tech, struct("buy", 0.5, "sell", -0.5));
exp_offline = ee_generate_offline_explanation(snap_tech);
audit_assert(size(exp_offline, 1) >= 40, "Mode A offline briefing generated complete comprehensive report (" + string(size(exp_offline, 1)) + " lines)");
audit_assert(strindex(strcat(exp_offline, " "), "METHODOLOGICAL WARNINGS") <> [], "Mode A contains regulatory disclaimer and warnings");

// Mode B: Mock AI execution
cfg_mock = ee_default_config();
cfg_mock.mock_response_file = APP_DIR + "fixtures/mock_gemini_response.json";
[exp_mock_ai, stat_mock, mode_mock] = ee_generate_ai_explanation(snap_tech, cfg_mock);
audit_assert(strindex(strcat(exp_mock_ai, " "), "AI FORECAST BRIEFING") <> [] | strindex(strcat(exp_mock_ai, " "), "Google Gemini API") <> [], "Mode B mock AI produced structured briefing");

// Fallback path: Unconfigured key
cfg_nokey = ee_default_config();
cfg_nokey.api_key = "";
[lines_unconf, stat_unconf, mode_unconf] = ee_generate_ai_explanation(snap_tech, cfg_nokey);
audit_assert(strindex(strcat(lines_unconf, " "), "EXECUTIVE FORECAST SUMMARY") <> [], "Unconfigured key gracefully falls back to deterministic briefing");
audit_assert(mode_unconf == "OFFLINE_DETERMINISTIC", "Mode correctly identifies OFFLINE_DETERMINISTIC");

// Fallback path: Network failure & banner injection
cfg_badnet = ee_default_config();
cfg_badnet.api_key = "AIzaSyD_TEST_SECRET_987654";
cfg_badnet.base_url = "https://invalid-host-name-stockvision-9999.com";
cfg_badnet.timeout_seconds = 2;
[lines_badnet, stat_badnet, mode_badnet] = ee_generate_ai_explanation(snap_tech, cfg_badnet);
audit_assert(mode_badnet == "FALLBACK_TO_OFFLINE", "Network failure gracefully triggers FALLBACK_TO_OFFLINE");
audit_assert(strindex(strcat(lines_badnet, " "), "[AI MODE DIAGNOSTIC NOTICE]") <> [], "Diagnostic notice banner injected on network failure");
audit_assert(strindex(strcat(lines_badnet, " "), "TEST_SECRET_987654") == [], "API key redacted from error banner");

// API key masking in error sanitization
leak_test = ee_sanitize_error("HTTP 401: Unauthorized for https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash?key=AIzaSySecretKeyXYZ", "AIzaSySecretKeyXYZ");
audit_assert(strindex(leak_test, "AIzaSySecretKeyXYZ") == [], "API key strictly sanitized from diagnostic string");
audit_assert(strindex(leak_test, "***MASKED***") <> [] | strindex(leak_test, "***MASKED_API_KEY***") <> [], "Sanitization leaves masked replacement token");

// --- Subsystem 8: Report Export Verification (TXT and CSV) ---
mprintf("\n--- Subsystem 8: Report Export Verification (TXT, Single CSV, Companion CSVs) ---\n");
rep_export = struct("dataset_label", "Tech Growth Stock (synthetic)", "data", d_tech, "dq", data_quality_summary(d_tech, 0.8), ..
                    "cfg", cfg, "analysis", r_tech_lr, "naive", cmp_tech.results(1), "signal", generate_signal(d_tech.close($), r_tech_lr.next_price, cfg.buy, cfg.sell), ..
                    "validated", %t, "cmp", cmp_tech, "bt", bt_tech, "assump", assumptions_struct(d_tech, data_quality_summary(d_tech, 0.8), cfg), ..
                    "explanation", exp_offline);

export_dir = APP_DIR + "outputs/exports/";
if ~isdir(export_dir) then mkdir(export_dir); end
test_txt_path = export_dir + "e2e_audit_report.txt";
test_csv_path = export_dir + "e2e_audit_metrics.csv";
if isfile(test_txt_path) then mdelete(test_txt_path); end
if isfile(test_csv_path) then mdelete(test_csv_path); end

export_report_txt(test_txt_path, rep_export);
audit_assert(isfile(test_txt_path), "export_report_txt wrote e2e_audit_report.txt");
txt_content = mgetl(test_txt_path);
audit_assert(strindex(strcat(txt_content, " "), "STOCKVISION V3 RESULTS REPORT") <> [], "TXT report contains header");
audit_assert(strindex(strcat(txt_content, " "), "FORECAST INTELLIGENCE & EXPLANATION") <> [], "TXT report includes Forecast Intelligence section");
audit_assert(strindex(strcat(txt_content, " "), "Tech Growth Stock") <> [], "TXT report contains correct asset label");

export_results_csv(test_csv_path, rep_export);
audit_assert(isfile(test_csv_path), "export_results_csv wrote e2e_audit_metrics.csv");
csv_content = mgetl(test_csv_path);
audit_assert(strindex(strcat(csv_content, " "), "Metric,Value") <> [], "CSV file has Metric,Value header");
audit_assert(strindex(strcat(csv_content, " "), "Theil_U2_vs_Naive") <> [], "CSV contains Theil_U2_vs_Naive row");
audit_assert(strindex(strcat(csv_content, " "), "WalkForward_RMSE_Ridge") <> [], "CSV contains WalkForward_RMSE_Ridge row for 5-model comparison");

// --- Subsystem 9: Reproducible Benchmark Verification ---
mprintf("\n--- Subsystem 9: Reproducible Benchmark Verification ---\n");
bm_summary = APP_DIR + "../../06_Sample_Outputs/benchmarks/benchmark_summary.csv";
bm_report = APP_DIR + "../../06_Sample_Outputs/benchmarks/benchmark_report.txt";
audit_assert(isfile(bm_summary), "Canonical benchmark_summary.csv verified");
audit_assert(isfile(bm_report), "Canonical benchmark_report.txt verified");

mprintf("\n======================================================================\n");
mprintf("  E2E Audit Verification Summary\n");
mprintf("  Total Passed Checks : %d\n", audit_passed);
mprintf("  Total Failed Checks : %d\n", audit_failures);
mprintf("  Total Skipped Checks: %d\n", audit_skipped);
mprintf("======================================================================\n");

if audit_failures > 0 then
    error("E2E Audit Verification encountered " + string(audit_failures) + " failure(s).");
    exit(1);
else
    mprintf("ALL REQUIRED END-TO-END WORKFLOW SUBSYSTEMS VERIFIED AND RELEASE READY.\n");
    exit(0);
end
