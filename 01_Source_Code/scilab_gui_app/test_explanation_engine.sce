// ============================================================================
// test_explanation_engine.sce -- Verification Suite for StockVision Phase 3
//
// Tests:
//   - Configuration management & API credential sanitization
//   - Structured snapshot generation and field extraction
//   - Multi-model disagreement and consensus calculations
//   - Theil U1 and U2 interpretation across outperformance/parity/underperformance
//   - Prediction intervals and uncertainty calibration diagnostics
//   - Bit-for-bit deterministic offline reproducibility (Mode A)
//   - Small sample and data quality anomaly guards
//   - Real market data provenance and local cache freshness
//   - Evidence-grounded prompt construction (zero hallucination)
//   - Mode B mocked AI parsing and validation
//   - Network failure, HTTP error handling, and graceful fallback to Mode A
//   - GUI integration, tab switching, and stale-result protection
//
// Run headlessly:
//   WScilex-cli.exe -nb -f test_explanation_engine.sce
// ============================================================================

clear; clc;

_DIR = "";
try
    _DIR = get_absolute_file_path("test_explanation_engine.sce");
catch
    _DIR = pwd() + filesep();
end

// Track assertion counts
global n_pass n_fail;
n_pass = 0;
n_fail = 0;

function assert_true(cond, msg)
    global n_pass n_fail;
    if cond then
        n_pass = n_pass + 1;
        mprintf("  [PASS] %s\n", msg);
    else
        n_fail = n_fail + 1;
        mprintf("  [FAIL] %s\n", msg);
    end
endfunction

function assert_equal(actual, expected, msg)
    global n_pass n_fail;
    if actual == expected then
        n_pass = n_pass + 1;
        mprintf("  [PASS] %s\n", msg);
    else
        n_fail = n_fail + 1;
        mprintf("  [FAIL] %s (Expected: %s, Got: %s)\n", msg, string(expected), string(actual));
    end
endfunction

mprintf("======================================================================\n");
mprintf("  StockVision Phase 3: AI Explanation Assistant Test Suite\n");
mprintf("======================================================================\n\n");

// Load modules
exec(_DIR + "model_engine.sce", -1);
exec(_DIR + "market_data_adapter.sce", -1);
exec(_DIR + "explanation_engine.sce", -1);


// ============================================================================
// Group 1: Configuration Management & Credential Security
// ============================================================================
mprintf("\n--- Group 1: Configuration Management & Credential Security ---\n");

cfg_def = ee_default_config();
assert_equal(cfg_def.provider, "gemini", "Default provider is gemini");
assert_equal(cfg_def.model, "gemini-1.5-flash", "Default model is gemini-1.5-flash");
assert_equal(cfg_def.timeout_seconds, 15, "Default timeout is 15 seconds");
assert_equal(cfg_def.fallback_to_offline, %t, "Fallback to offline enabled by default");

// Env var resolution test
setenv("STOCKVISION_AI_KEY", "test_secret_key_env_9988");
cfg_loaded = ee_load_config();
assert_equal(cfg_loaded.api_key, "test_secret_key_env_9988", "Environment variable STOCKVISION_AI_KEY overrides config");
setenv("STOCKVISION_AI_KEY", "");

// Credential masking tests
raw_err1 = "Failed to connect to https://generativelanguage.googleapis.com/v1beta/models?key=AIzaSyD_SECRET_123456789";
clean_err1 = ee_sanitize_error(raw_err1, "AIzaSyD_SECRET_123456789");
assert_true(strindex(clean_err1, "SECRET_123456789") == [], "API key query param masked from error string");
assert_true(strindex(clean_err1, "***MASKED***") <> [] | strindex(clean_err1, "***MASKED_API_KEY***") <> [], "Masked replacement token present");

raw_err2 = "Authorization error with token AIzaSyD_SECRET_123456789 in HTTP response";
clean_err2 = ee_sanitize_error(raw_err2, "AIzaSyD_SECRET_123456789");
assert_true(strindex(clean_err2, "SECRET_123456789") == [], "Explicit secret string masked from plain text error");


// ============================================================================
// Group 2: Snapshot Construction & Schema Invariants
// ============================================================================
mprintf("\n--- Group 2: Snapshot Construction & Schema Invariants ---\n");

d_empty = struct();
snap_empty = ee_build_snapshot(d_empty, [], [], [], [], [], struct());
assert_equal(snap_empty.has_data, %f, "Empty dataset flagged as has_data=F");
assert_equal(snap_empty.has_analysis, %f, "Empty analysis flagged as has_analysis=F");
assert_equal(snap_empty.symbol, "NONE", "Empty snapshot symbol is NONE");

d_tech = load_dataset(_DIR + "sample_data/tech_growth_stock.csv");
r_lr = run_model(d_tech, "LR", round(d_tech.n * 0.8), 10, 0.3, 0.1);
nv_lr = run_model(d_tech, "NAIVE", round(d_tech.n * 0.8), 10, 0.3, 0.1);
params = struct("buy", 0.5, "sell", -0.5, "capital", 100000, "cost", 0.1, "slip", 0.05);

snap_tech = ee_build_snapshot(d_tech, r_lr, nv_lr, [], [], [], params);
assert_equal(snap_tech.has_data, %t, "Tech dataset loaded into snapshot");
assert_equal(snap_tech.has_analysis, %t, "LR analysis loaded into snapshot");
assert_equal(snap_tech.total_bars, 300, "Total bars strictly matches dataset length (300)");
assert_equal(snap_tech.forecast_horizon, "1 trading day (next close)", "Forecast horizon is strictly 1 trading day");
assert_equal(snap_tech.last_close, d_tech.close($), "Last observed close matches dataset close($)");
assert_true(snap_tech.active_next_price > 0, "Point forecast is positive");
assert_equal(snap_tech.active_signal, "BUY", "0.67% predicted change produces BUY signal");
assert_equal(snap_tech.train_rows, 240, "Training rows matches 80% split (240)");
assert_equal(snap_tech.test_rows, 60, "Test rows matches 20% test window (60)");


// ============================================================================
// Group 3: Multi-Model Disagreement & Consensus Metrics
// ============================================================================
mprintf("\n--- Group 3: Multi-Model Disagreement & Consensus Metrics ---\n");

cmp_all = compare_models(d_tech, 0.8, 10, 0.3, 0.1, 5, %t);
snap_cmp = ee_build_snapshot(d_tech, r_lr, nv_lr, cmp_all, [], [], params);

assert_equal(snap_cmp.has_comparison, %t, "Comparison present in snapshot");
assert_equal(snap_cmp.n_models, 5, "5 models compared (Naive, LR, AR, ES, Ridge)");
assert_true(snap_cmp.spread_abs > 0, "Absolute spread across model forecasts is strictly positive");
assert_true(snap_cmp.spread_pct > 0, "Percentage spread across model forecasts is strictly positive");
assert_true(snap_cmp.max_forecast >= snap_cmp.min_forecast, "Max forecast >= Min forecast");
assert_equal(snap_cmp.min_forecast, min(snap_cmp.cmp_forecasts), "Min forecast matches vector minimum");
assert_equal(snap_cmp.max_forecast, max(snap_cmp.cmp_forecasts), "Max forecast matches vector maximum");
assert_true(snap_cmp.n_models_up + snap_cmp.n_models_down + snap_cmp.n_models_flat == 5, "Directional consensus sums to total model count (5)");
assert_true(length(snap_cmp.directional_consensus) > 5, "Consensus outlook string populated");


// ============================================================================
// Group 4: Theil U1 & U2 Interpretation
// ============================================================================
mprintf("\n--- Group 4: Theil U1 & U2 Interpretation ---\n");

// Test U2 < 1.0 (Outperformance)
snap_u2_good = snap_tech;
snap_u2_good.theil_u2_vs_naive = 0.75;
lines_good = ee_generate_offline_explanation(snap_u2_good);
text_good = strcat(lines_good, " ");
assert_true(strindex(text_good, "predictive skill") <> [] | strindex(text_good, "reduction") <> [], "U2 < 1.0 correctly explained as genuine predictive skill");

// Test U2 > 1.0 (Underperformance / Random walk)
snap_u2_bad = snap_tech;
snap_u2_bad.theil_u2_vs_naive = 1.15;
lines_bad = ee_generate_offline_explanation(snap_u2_bad);
text_bad = strcat(lines_bad, " ");
assert_true(strindex(text_bad, "underperformance") <> [] | strindex(text_bad, "higher out-of-sample error") <> [], "U2 > 1.0 correctly explained as underperformance vs random walk");

// Test U2 ~ 1.0 (Parity)
snap_u2_par = snap_tech;
snap_u2_par.theil_u2_vs_naive = 1.00;
lines_par = ee_generate_offline_explanation(snap_u2_par);
text_par = strcat(lines_par, " ");
assert_true(strindex(text_par, "parity with random walk") <> [], "U2 ~ 1.0 correctly explained as random walk parity");

// Test Naive #1 rank detection
snap_naive_first = snap_cmp;
snap_naive_first.naive_beats_all = %t;
lines_nf = ee_generate_offline_explanation(snap_naive_first);
text_nf = strcat(lines_nf, " ");
assert_true(strindex(text_nf, "CRITICAL BENCHMARK FINDING: Naive persistence") <> [], "Naive #1 rank prominently flagged to user");


// ============================================================================
// Group 5: Prediction Intervals & Uncertainty Calibration
// ============================================================================
mprintf("\n--- Group 5: Prediction Intervals & Uncertainty Calibration ---\n");

assert_equal(snap_tech.has_valid_ci, %t, "LR prediction interval flagged as valid");
assert_true(snap_tech.active_ci_lo < snap_tech.active_next_price, "Interval lower bound strictly below point prediction");
assert_true(snap_tech.active_ci_hi > snap_tech.active_next_price, "Interval upper bound strictly above point prediction");
assert_true(snap_tech.active_ci_width > 0, "Interval width strictly positive");

// Test degenerate interval guard
snap_degen = snap_tech;
snap_degen.active_ci_lo = 180.0;
snap_degen.active_ci_hi = 170.0; // Inverted
snap_degen.has_valid_ci = %f;
lines_degen = ee_generate_offline_explanation(snap_degen);
text_degen = strcat(lines_degen, " ");
assert_true(strindex(text_degen, "UNAVAILABLE or DEGENERATE") <> [], "Degenerate prediction interval flagged without crash");


// ============================================================================
// Group 6: Deterministic Offline Reproducibility (Mode A)
// ============================================================================
mprintf("\n--- Group 6: Deterministic Offline Reproducibility (Mode A) ---\n");

lines_run1 = ee_generate_offline_explanation(snap_cmp);
lines_run2 = ee_generate_offline_explanation(snap_cmp);

assert_equal(size(lines_run1, 1), size(lines_run2, 1), "Repeated offline runs produce identical line counts");
is_identical = %t;
for i = 1:size(lines_run1, 1)
    if lines_run1(i) <> lines_run2(i) then is_identical = %f; break; end
end
assert_true(is_identical, "Offline explanation is 100% bit-for-bit deterministic and reproducible");

full_text = strcat(lines_run1, ascii(10));
assert_true(strindex(full_text, "--- 1. EXECUTIVE FORECAST SUMMARY ---") <> [], "Section 1 present");
assert_true(strindex(full_text, "--- 2. MULTI-MODEL FORECAST COMPARISON & DISAGREEMENT ---") <> [], "Section 2 present");
assert_true(strindex(full_text, "--- 3. EMPIRICAL VALIDATION & BENCHMARK EVALUATION ---") <> [], "Section 3 present");
assert_true(strindex(full_text, "--- 4. UNCERTAINTY & RISK ASSESSMENT ---") <> [], "Section 4 present");
assert_true(strindex(full_text, "--- 5. DATA QUALITY & PROVENANCE ASSESSMENT ---") <> [], "Section 5 present");
assert_true(strindex(full_text, "--- 6. METHODOLOGICAL WARNINGS & LIMITATIONS ---") <> [], "Section 6 present");
assert_true(strindex(full_text, "--- 7. SUGGESTED ANALYTICAL ACTIONS ---") <> [], "Section 7 present");
assert_true(strindex(full_text, "NO GUARANTEED RETURNS") <> [], "Mandatory regulatory disclaimer present");


// ============================================================================
// Group 7: Small Sample & Data Quality Anomaly Guards
// ============================================================================
mprintf("\n--- Group 7: Small Sample & Data Quality Anomaly Guards ---\n");

// Small sample size (n < 30)
snap_small = snap_tech;
snap_small.total_bars = 24;
lines_small = ee_generate_offline_explanation(snap_small);
text_small = strcat(lines_small, " ");
assert_true(strindex(text_small, "CRITICAL SAMPLE SIZE DEFICIT") <> [], "n < 30 triggers critical sample size deficit warning");

// Data anomalies detection
snap_anom = snap_tech;
snap_anom.anomalies_detected = 3;
snap_anom.price_jumps = 1;
snap_anom.zero_volume_bars = 1;
snap_anom.date_gaps = 1;
lines_anom = ee_generate_offline_explanation(snap_anom);
text_anom = strcat(lines_anom, " ");
assert_true(strindex(text_anom, "3 data irregularities flagged") <> [], "Anomaly counts accurately detailed in briefing");


// ============================================================================
// Group 8: Market Data Provenance & Cache Freshness
// ============================================================================
mprintf("\n--- Group 8: Market Data Provenance & Cache Freshness ---\n");

mock_aapl_path = _DIR + "sample_data/mock_market_data/mock_twelvedata_aapl.json";
d_aapl = mda_load_mock(mock_aapl_path, "AAPL", "NASDAQ");
r_aapl = run_model(d_aapl, "RIDGE", round(d_aapl.n * 0.8), 10, 0.3, 0.1);
nv_aapl = run_model(d_aapl, "NAIVE", round(d_aapl.n * 0.8), 10, 0.3, 0.1);
snap_aapl = ee_build_snapshot(d_aapl, r_aapl, nv_aapl, [], [], [], params);

assert_equal(snap_aapl.symbol, "AAPL", "Market symbol AAPL preserved in snapshot");
assert_equal(snap_aapl.exchange, "NASDAQ", "Exchange NASDAQ preserved in snapshot");
assert_equal(snap_aapl.currency, "USD", "Currency USD preserved in snapshot");
assert_equal(snap_aapl.provider, "Twelve Data", "Provider Twelve Data preserved in snapshot");
lines_aapl = ee_generate_offline_explanation(snap_aapl);
text_aapl = strcat(lines_aapl, " ");
assert_true(strindex(text_aapl, "Twelve Data") <> [], "Twelve Data attribution in briefing");


// ============================================================================
// Group 9: Evidence-Grounded AI Prompt Construction
// ============================================================================
mprintf("\n--- Group 9: Evidence-Grounded AI Prompt Construction ---\n");

prompt_str = ee_build_grounding_prompt(snap_aapl);
assert_true(strindex(prompt_str, "CRITICAL CONSTRAINTS & GROUNDING RULES") <> [], "Grounding rules embedded in prompt");
assert_true(strindex(prompt_str, "Asset Symbol: AAPL") <> [], "Asset symbol strictly serialized");
assert_true(strindex(prompt_str, "NEVER promise or guarantee financial returns") <> [], "No-guarantee invariant enforced in system prompt");
assert_true(strindex(prompt_str, "Do NOT invent stock prices") <> [], "Anti-hallucination constraint enforced");
assert_true(strindex(prompt_str, _DIR) == [], "Local absolute file paths excluded from external AI prompt");


// ============================================================================
// Group 10: Mode B Mocked AI Response & Parsing
// ============================================================================
mprintf("\n--- Group 10: Mode B Mocked AI Response & Parsing ---\n");

cfg_mock = ee_default_config();
cfg_mock.mock_response_file = _DIR + "fixtures/mock_gemini_response.json";

[ai_lines, ai_status, ai_mode] = ee_generate_ai_explanation(snap_aapl, cfg_mock);
assert_equal(ai_mode, "AI_GEMINI_MOCK", "Mock AI mode identified");
assert_equal(ai_status, "SUCCESS_AI_MOCK", "Mock AI status reported");
ai_text = strcat(ai_lines, " ");
assert_true(strindex(ai_text, "Google Gemini API") <> [], "Gemini header present in output");
assert_true(strindex(ai_text, "EXECUTIVE SUMMARY") <> [], "Structured candidate text parsed");
assert_true(strindex(ai_text, "Does not constitute financial or investment advice") <> [] | strindex(ai_text, "Notice:") <> [], "Disclaimer attached to AI response");


// ============================================================================
// Group 11: Network Failure & Graceful Fallback to Mode A
// ============================================================================
mprintf("\n--- Group 11: Network Failure & Graceful Fallback to Mode A ---\n");

// Missing API key fallback
cfg_nokey = ee_default_config();
cfg_nokey.api_key = "";
[lines_fb1, status_fb1, mode_fb1] = ee_generate_ai_explanation(snap_aapl, cfg_nokey);
assert_equal(mode_fb1, "OFFLINE_DETERMINISTIC", "Missing API key seamlessly uses Mode A");
assert_true(strindex(status_fb1, "No AI API key configured") <> [], "Status informs user of keyless state");

// Network error fallback
cfg_badnet = ee_default_config();
cfg_badnet.api_key = "AIzaSyD_TEST_SECRET_987654";
cfg_badnet.base_url = "https://invalid-host-name-stockvision-9999.com";
cfg_badnet.timeout_seconds = 2;

[lines_fb2, status_fb2, mode_fb2] = ee_generate_ai_explanation(snap_aapl, cfg_badnet);
assert_equal(mode_fb2, "FALLBACK_TO_OFFLINE", "Network failure triggers graceful fallback");
assert_true(strindex(status_fb2, "FALLBACK_OFFLINE") <> [], "Status reports fallback");
fb_text = strcat(lines_fb2, " ");
assert_true(strindex(fb_text, "[AI MODE DIAGNOSTIC NOTICE]") <> [], "Diagnostic notice banner prepended");
assert_true(strindex(fb_text, "TEST_SECRET_987654") == [], "API key redacted from error diagnostic");
assert_true(strindex(fb_text, "--- 1. EXECUTIVE FORECAST SUMMARY ---") <> [], "Complete deterministic briefing follows banner");


// ============================================================================
// Group 12: GUI Integration & Workflow State
// ============================================================================
mprintf("\n--- Group 12: GUI Integration & Workflow State ---\n");

// Preserve pass/fail counters in environment variables across gui_app.sce clear
setenv("P3_PASS", string(n_pass));
setenv("P3_FAIL", string(n_fail));

global gui_quiet gui app_state;
gui_quiet = %t;
exec(_DIR + "gui_app.sce", -1);

global n_pass n_fail;
n_pass = evstr(getenv("P3_PASS", "0"));
n_fail = evstr(getenv("P3_FAIL", "0"));

function assert_true(cond, msg)
    global n_pass n_fail;
    if cond then
        n_pass = n_pass + 1;
        mprintf("  [PASS] %s\n", msg);
    else
        n_fail = n_fail + 1;
        mprintf("  [FAIL] %s\n", msg);
    end
endfunction

function assert_equal(actual, expected, msg)
    global n_pass n_fail;
    if actual == expected then
        n_pass = n_pass + 1;
        mprintf("  [PASS] %s\n", msg);
    else
        n_fail = n_fail + 1;
        mprintf("  [FAIL] %s (Expected: %s, Got: %s)\n", msg, string(expected), string(actual));
    end
endfunction

assert_true(isfield(gui, "tab_ai"), "AI Insights tab widget exists in GUI");
assert_true(isfield(gui, "btn_explain"), "Explain Forecast button exists in GUI");
assert_true(isfield(gui, "ai_mode_popup"), "Explanation mode popup exists in GUI");

// Initial state
assert_equal(get(gui.btn_explain, "enable"), "off", "Explain button disabled before analysis");

// Run analysis
on_run_analysis();
assert_equal(get(gui.btn_explain, "enable"), "on", "Explain button enabled after analysis");

// Click Explain Forecast
on_explain();
assert_equal(app_state.info_tab, "ai", "on_explain activates AI Insights tab");
assert_equal(get(gui.tab_ai, "fontweight"), "bold", "AI Insights tab is bolded");
assert_equal(get(gui.tab_dq, "fontweight"), "normal", "Data Quality tab is normalized");
assert_true(size(app_state.info_ai, 1) > 20, "AI Insights panel contains complete briefing");

// Change dataset -> verify explanation is cleared (stale data protection)
set(gui.dataset_popup, "value", 2);
on_dataset_changed();
assert_true(size(app_state.ai_explanation, "*") == 0, "Dataset change clears previous stock explanation");

// Single window invariant
assert_equal(size(winsid(), "*"), 1, "Exactly ONE graphics figure remains open after explanation");


// ============================================================================
// Final Scorecard
// ============================================================================
mprintf("\n======================================================================\n");
mprintf("  Phase 3 Explanation Assistant Results\n");
mprintf("  Total assertions: %d\n", n_pass + n_fail);
mprintf("  Passed:           %d\n", n_pass);
mprintf("  Failed:           %d\n", n_fail);
mprintf("======================================================================\n");

if n_fail == 0 then
    mprintf("ALL PHASE 3 EXPLANATION ASSISTANT TESTS PASSED SUCCESSFULLY.\n");
    exit(0);
else
    error("Phase 3 verification failed with " + string(n_fail) + " failure(s).");
    exit(1);
end
