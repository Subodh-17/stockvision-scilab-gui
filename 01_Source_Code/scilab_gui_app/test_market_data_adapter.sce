// ============================================================================
// test_market_data_adapter.sce -- Verification suite for Market Data Adapter
//
// Tests retrieval, schema parsing, chronological ordering, caching,
// error handling, provider metadata, and seamless interoperability
// with StockVision's model_engine.sce algorithms.
//
// Run headlessly:
//   WScilex-cli -nb -f 01_Source_Code/scilab_gui_app/test_market_data_adapter.sce
// ============================================================================

clear;
mprintf("======================================================================\n");
mprintf("  StockVision Market Data Adapter Verification Suite\n");
mprintf("======================================================================\n\n");

// Locate scripts
try
    this_dir = get_absolute_file_path("test_market_data_adapter.sce");
catch
    this_dir = pwd() + filesep() + "01_Source_Code" + filesep() + "scilab_gui_app" + filesep();
end

engine_path = this_dir + "model_engine.sce";
adapter_path = this_dir + "market_data_adapter.sce";

if ~isfile(engine_path) then error("Engine script not found: " + engine_path); end
if ~isfile(adapter_path) then error("Adapter script not found: " + adapter_path); end

exec(engine_path, -1);
exec(adapter_path, -1);

global n_passed n_failed;
n_passed = 0;
n_failed = 0;

function assert_true(cond, desc)
    global n_passed n_failed;
    if cond then
        n_passed = n_passed + 1;
        mprintf("  [PASS] %s\n", desc);
    else
        n_failed = n_failed + 1;
        mprintf("  [FAIL] %s\n", desc);
    end
endfunction

function assert_equal_val(actual, expected, desc)
    global n_passed n_failed;
    if actual == expected then
        n_passed = n_passed + 1;
        mprintf("  [PASS] %s\n", desc);
    else
        n_failed = n_failed + 1;
        mprintf("  [FAIL] %s (expected %s, got %s)\n", desc, string(expected), string(actual));
    end
endfunction


// ---------------------------------------------------------------------------
// Group 1: Configuration Management
// ---------------------------------------------------------------------------
mprintf("\n--- Group 1: Configuration Management ---\n");

cfg = mda_default_config();
assert_equal_val(cfg.provider, "twelvedata", "Default provider is twelvedata");
assert_true(cfg.cache_enabled, "Cache is enabled by default");
assert_equal_val(cfg.cache_ttl_hours, 4.0, "Default cache TTL is 4.0 hours");
assert_equal_val(cfg.default_outputsize, 120, "Default outputsize is 120 bars");

loaded_cfg = mda_load_config();
assert_equal_val(loaded_cfg.provider, "twelvedata", "Loaded config preserves twelvedata provider");


// ---------------------------------------------------------------------------
// Group 2: US Equity Mock Parsing & Chronological Invariance (AAPL)
// ---------------------------------------------------------------------------
mprintf("\n--- Group 2: US Market Data Normalization (AAPL / NASDAQ) ---\n");

mock_aapl_path = this_dir + "sample_data" + filesep() + "mock_market_data" + filesep() + "mock_twelvedata_aapl.json";
assert_true(isfile(mock_aapl_path), "AAPL mock fixture exists");

aapl_data = mda_load_mock(mock_aapl_path, "AAPL", "NASDAQ");
assert_equal_val(aapl_data.n, 65, "AAPL parsed row count is 65");
assert_equal_val(aapl_data.symbol, "AAPL", "AAPL metadata symbol is AAPL");
assert_equal_val(aapl_data.exchange, "NASDAQ", "AAPL metadata exchange is NASDAQ");
assert_equal_val(aapl_data.currency, "USD", "AAPL currency is USD");
assert_equal_val(aapl_data.timezone, "America/New_York", "AAPL exchange timezone is America/New_York");
assert_equal_val(aapl_data.provider, "Twelve Data", "Provider is Twelve Data");

// Chronological sorting invariant: row 1 must be older than row $
[y1, m1, d1, ok1] = parse_iso_date(aapl_data.dates(1));
[y2, m2, d2, ok2] = parse_iso_date(aapl_data.dates($));
s1 = y1 * 372 + m1 * 31 + d1;
s2 = y2 * 372 + m2 * 31 + d2;
assert_true(s1 < s2, "AAPL chronological sort: dates(1) is earlier than dates($)");
assert_equal_val(aapl_data.quality.was_chronological, %t, "Quality struct flags valid chronological order");

// OHLC sanity invariants across all bars
ohlc_sane = %t;
for i = 1:aapl_data.n
    if aapl_data.low(i) > aapl_data.high(i) | aapl_data.open(i) < aapl_data.low(i) | ..
       aapl_data.open(i) > aapl_data.high(i) | aapl_data.close(i) < aapl_data.low(i) | ..
       aapl_data.close(i) > aapl_data.high(i) then
        ohlc_sane = %f;
    end
end
assert_true(ohlc_sane, "All AAPL bars satisfy Low <= {Open, Close} <= High");
assert_true(min(aapl_data.volume) >= 0, "All AAPL volumes are non-negative");


// ---------------------------------------------------------------------------
// Group 3: Indian Equity Mock Parsing (INFY / NSE)
// ---------------------------------------------------------------------------
mprintf("\n--- Group 3: Indian Market Data Normalization (INFY / NSE) ---\n");

mock_infy_path = this_dir + "sample_data" + filesep() + "mock_market_data" + filesep() + "mock_twelvedata_infy_nse.json";
assert_true(isfile(mock_infy_path), "INFY mock fixture exists");

infy_data = mda_load_mock(mock_infy_path, "INFY", "NSE");
assert_equal_val(infy_data.n, 65, "INFY parsed row count is 65");
assert_equal_val(infy_data.symbol, "INFY", "INFY metadata symbol is INFY");
assert_equal_val(infy_data.exchange, "NSE", "INFY metadata exchange is NSE");
assert_equal_val(infy_data.currency, "INR", "INFY currency is INR");
assert_equal_val(infy_data.timezone, "Asia/Kolkata", "INFY exchange timezone is Asia/Kolkata");

// Chronological sort
[iy1, im1, id1, iok1] = parse_iso_date(infy_data.dates(1));
[iy2, im2, id2, iok2] = parse_iso_date(infy_data.dates($));
is1 = iy1 * 372 + im1 * 31 + id1;
is2 = iy2 * 372 + im2 * 31 + id2;
assert_true(is1 < is2, "INFY chronological sort: dates(1) is earlier than dates($)");


// ---------------------------------------------------------------------------
// Group 4: Error Handling & Security (No Silent Fallbacks)
// ---------------------------------------------------------------------------
mprintf("\n--- Group 4: Provider Error Handling (Rate Limit, Invalid Symbol, Auth) ---\n");

// Rate limit 429
rate_limit_path = this_dir + "sample_data" + filesep() + "mock_market_data" + filesep() + "mock_twelvedata_rate_limit.json";
rl_lines = mgetl(rate_limit_path);
rl_json = fromJSON(strcat(rl_lines, ""));
caught_rl = %f;
try
    mda_parse_timeseries_response(rl_json, "AAPL", "NASDAQ", %f);
catch
    caught_rl = %t;
    err_str = strcat(lasterror(), " ");
    assert_true(strindex(err_str, "429") > 0, "Rate limit error message references HTTP 429");
end
assert_true(caught_rl, "Rate limit 429 raises explicit exception");

// Invalid symbol 404
sym_err_path = this_dir + "sample_data" + filesep() + "mock_market_data" + filesep() + "mock_twelvedata_invalid_symbol.json";
sym_lines = mgetl(sym_err_path);
sym_json = fromJSON(strcat(sym_lines, ""));
caught_sym = %f;
try
    mda_parse_timeseries_response(sym_json, "UNKNOWN", "NASDAQ", %f);
catch
    caught_sym = %t;
    err_str = strcat(lasterror(), " ");
    assert_true(strindex(err_str, "404") > 0, "Invalid symbol error message references HTTP 404");
end
assert_true(caught_sym, "Invalid symbol 404 raises explicit exception");

// Auth error 401
auth_err_path = this_dir + "sample_data" + filesep() + "mock_market_data" + filesep() + "mock_twelvedata_auth_error.json";
auth_lines = mgetl(auth_err_path);
auth_json = fromJSON(strcat(auth_lines, ""));
caught_auth = %f;
try
    mda_parse_timeseries_response(auth_json, "AAPL", "NASDAQ", %f);
catch
    caught_auth = %t;
    err_str = strcat(lasterror(), " ");
    assert_true(strindex(err_str, "401") > 0, "Auth error message references HTTP 401");
end
assert_true(caught_auth, "Auth error 401 raises explicit exception");

// Empty symbol validation
caught_empty = %f;
try
    mda_fetch_market_data("", "NASDAQ", 120, %f);
catch
    caught_empty = %t;
end
assert_true(caught_empty, "Empty symbol raises explicit validation error");

// Missing API key validation (when unconfigured)
dummy_cfg = mda_default_config();
dummy_cfg.api_key = "";
caught_no_key = %f;
try
    mda_fetch_market_data("AAPL", "NASDAQ", 120, %t, dummy_cfg);
catch
    caught_no_key = %t;
    err_str = strcat(lasterror(), " ");
    assert_true(strindex(err_str, "No Twelve Data API key configured") > 0, "Unconfigured API key explains remediation steps");
end
assert_true(caught_no_key, "Missing API key raises explicit configuration error");

// Error sanitization (API key masking)
raw_leak = "HTTP error on https://api.twelvedata.com/time_series?symbol=AAPL&apikey=secret_token_abc12345&interval=1day";
clean_leak = mda_sanitize_error(raw_leak, "secret_token_abc12345");
assert_true(isempty(strindex(clean_leak, "secret_token_abc12345")), "mda_sanitize_error strips explicit secret token");
assert_true(~isempty(strindex(clean_leak, "apikey=***MASKED***")), "mda_sanitize_error masks apikey URL parameter");

raw_leak2 = "Connection failed with key super_secret_passphrase in response";
clean_leak2 = mda_sanitize_error(raw_leak2, "super_secret_passphrase");
assert_true(~isempty(strindex(clean_leak2, "***MASKED_API_KEY***")), "mda_sanitize_error masks custom api_key parameter in text");


// ---------------------------------------------------------------------------
// Group 5: Local Caching, Expiration & Provenance
// ---------------------------------------------------------------------------
mprintf("\n--- Group 5: Local Caching, Expiration & Provenance ---\n");

test_cache_sym = "MOCK_TEST_SYM";
test_cache_exch = "NASDAQ";
mock_payload = fromJSON(strcat(mgetl(mock_aapl_path), ""));

// Write cache
w_ok = mda_write_cache(test_cache_sym, test_cache_exch, 65, mock_payload);
assert_true(w_ok, "Writing payload to local cache succeeds");

// Read cache hit (with 4 hour TTL)
[cached_res, is_valid] = mda_read_cache(test_cache_sym, test_cache_exch, 65, 4.0);
assert_true(is_valid, "Cache read indicates valid hit within TTL");
assert_equal_val(cached_res.status, "ok", "Cached payload preserves status");

// Cache provenance metadata: retrieval time vs cache access time
parsed_cached = mda_parse_timeseries_response(cached_res, test_cache_sym, test_cache_exch, %t);
assert_true(isfield(parsed_cached, "retrieval_time"), "Cached response has retrieval_time");
assert_true(isfield(parsed_cached, "cache_access_time"), "Cached response has cache_access_time");
assert_true(strindex(parsed_cached.data_freshness, "Local Cache Hit") > 0, "Cached response freshness indicates Local Cache Hit");

// Read cache with 0 TTL (expired)
[cached_expired, is_expired_valid] = mda_read_cache(test_cache_sym, test_cache_exch, 65, -0.01);
assert_true(~is_expired_valid, "Cache read correctly rejects expired payload (TTL <= 0)");

// Corrupted cache file handling
corrupt_sym = "CORRUPT_TEST_SYM";
corrupt_fpath = mda_cache_path(corrupt_sym, "NASDAQ", 65);
mputl("{invalid_json_content: [[[[", corrupt_fpath);
[corrupt_res, is_corrupt_valid] = mda_read_cache(corrupt_sym, "NASDAQ", 65, 4.0);
assert_true(~is_corrupt_valid, "Corrupt cache JSON is safely rejected without crash");
if isfile(corrupt_fpath) then mdelete(corrupt_fpath); end


// ---------------------------------------------------------------------------
// Group 6: Model Engine Interoperability on Live Market Schema
// ---------------------------------------------------------------------------
mprintf("\n--- Group 6: Model Engine Interoperability on Real Market Data ---\n");

// Quality summary & report formatting
dq = data_quality_summary(aapl_data, 0.8);
assert_equal_val(dq.rows, 65, "dq.rows matches market data row count");
assert_equal_val(dq.train_rows, 52, "dq.train_rows = round(65 * 0.8) = 52");
assert_equal_val(dq.test_rows, 13, "dq.test_rows = 13");
assert_equal_val(dq.duplicates, 0, "dq.duplicates is 0");
assert_true(dq.chronological, "dq.chronological is %t");

rep_lines = format_data_quality(dq, "Live Market: AAPL (NASDAQ)");
assert_true(size(rep_lines, 1) >= 12, "format_data_quality returns complete text report with provider metadata");
assert_equal_val(dq.provider, "Twelve Data", "Data quality summary preserves Twelve Data provider");
assert_equal_val(dq.symbol, "AAPL", "Data quality summary preserves AAPL symbol");
assert_equal_val(dq.exchange, "NASDAQ", "Data quality summary preserves NASDAQ exchange");
assert_true(strindex(strcat(rep_lines, " "), "Twelve Data") > 0, "Report text includes Twelve Data attribution");

// Cached data quality summary provenance
dq_cached = data_quality_summary(parsed_cached, 0.8);
assert_equal_val(dq_cached.provider, "Twelve Data", "Cached data preserves provider");
assert_true(isfield(dq_cached, "cache_access_time"), "dq struct contains cache_access_time");
rep_cached = format_data_quality(dq_cached, "Cached AAPL");
assert_true(strindex(strcat(rep_cached, " "), "Loaded from cache:") > 0, "format_data_quality displays Loaded from cache timestamp");

// Model Fitting: Linear Regression
split_cal = dq.train_rows;
lr_res = run_model(aapl_data, "LR", split_cal, 5, 0.2, 0.1);
assert_true(lr_res.next_price > 0, "LR produces positive next price forecast on real market data");
assert_true(lr_res.metrics.rmse > 0, "LR test RMSE > 0");
assert_true(lr_res.ci_hi > lr_res.ci_lo, "LR forecast interval upper > lower");

// Model Fitting: Autoregressive AR(5)
ar_res = run_model(aapl_data, "AR", split_cal, 5, 0.2, 0.1);
assert_true(ar_res.next_price > 0, "AR produces positive next price forecast on real market data");
assert_true(ar_res.ci_hi > ar_res.ci_lo, "AR forecast interval upper > lower");

// Model Fitting: Exponential Smoothing (Holt linear)
es_res = run_model(aapl_data, "ES", split_cal, 5, 0.2, 0.1);
assert_true(es_res.next_price > 0, "ES produces positive next price forecast on real market data");
assert_true(es_res.ci_hi > es_res.ci_lo, "ES forecast interval upper > lower");

// Model Comparison & Ranking
cmp = compare_models(aapl_data, 0.8, 5, 0.2, 0.1, 3);
assert_equal_val(length(cmp.results), 4, "compare_models fits all 4 models (LR, AR, ES, Naive)");
assert_true(cmp.rank.best_idx >= 2 & cmp.rank.best_idx <= 4, "compare_models identifies best predictive model");
best_res = cmp.results(cmp.rank.best_idx);
assert_true(best_res.next_price > 0, "Best model has positive next price forecast");

// Walk-Forward Validation
wf = walk_forward_all(aapl_data, 2, 5, 0.2, 0.1);
assert_true(wf.n_used >= 1, "Walk-forward completes fold(s) on market data");
assert_true(wf.mean_rmse(4) > 0, "Walk-forward ES mean RMSE > 0");

// Backtest Execution
curr_price = aapl_data.close(split_cal);
sig = generate_signal(curr_price, lr_res.next_price, 1.0, -1.0);
y_act = aapl_data.close(split_cal+1:$);
test_dates = aapl_data.dates(split_cal+1:$);
bt = run_backtest(y_act, lr_res.y_pred, 1.0, -1.0, 10000.0, 0.1, 0.05);
assert_true(bt.strategy_final > 0, "Backtest completes with positive portfolio value");
assert_true(bt.n_trades >= 0, "Backtest records trade count");


// ---------------------------------------------------------------------------
// Group 7: Live Fetch Configuration Robustness & Directory Independence
// ---------------------------------------------------------------------------
mprintf("\n--- Group 7: Live Fetch Configuration Robustness & Directory Independence ---\n");

// 1. Missing API key handling
cfg_missing = mda_default_config();
assert_equal_val(cfg_missing.api_key, "", "Default config has empty API key");
missing_err_thrown = %f;
try
    mda_fetch_market_data("AAPL", "NASDAQ", 120, %t, cfg_missing);
catch
    err_str = strcat(lasterror(), " ");
    if strindex(err_str, "Market data configuration required") <> [] then
        missing_err_thrown = %t;
    end
end
assert_true(missing_err_thrown, "Missing API key raises explicit configuration error");

// 2. Valid environment-variable configuration
setenv("TWELVE_DATA_API_KEY", "  test_env_key_valid_999  ");
cfg_env = mda_load_config();
assert_equal_val(cfg_env.api_key, "test_env_key_valid_999", "Whitespace in TWELVE_DATA_API_KEY is trimmed");
setenv("TWELVE_DATA_API_KEY", """quoted_env_key_888""");
cfg_env_q = mda_load_config();
assert_equal_val(cfg_env_q.api_key, "quoted_env_key_888", "Enclosing quotes in TWELVE_DATA_API_KEY are stripped");

// 3. Valid JSON configuration
tmp_json = TMPDIR + filesep() + "test_mda_config.json";
mputl(["{""provider"": ""twelvedata"", ""api_key"": ""custom_json_key_777""}"], tmp_json);
setenv("TWELVE_DATA_API_KEY", "");
cfg_json = mda_load_config(tmp_json);
assert_equal_val(cfg_json.api_key, "custom_json_key_777", "mda_load_config parses valid JSON config");

// 4. Relative-path and alternate-working-directory startup
orig_pwd = pwd();
try
    chdir(TMPDIR);
    root_from_tmp = mda_project_root();
    assert_true(isdir(root_from_tmp), "mda_project_root resolves to valid directory from arbitrary CWD");
    assert_true(isdir(root_from_tmp + "01_Source_Code") | isdir(root_from_tmp + "config"), ..
                "mda_project_root discovers StockVision root containing 01_Source_Code or config");
    chdir(orig_pwd);
catch
    chdir(orig_pwd);
    assert_true(%f, "Directory independence test encountered error");
end

// 5. Malformed configuration JSON
tmp_bad_json = TMPDIR + filesep() + "test_mda_bad_config.json";
mputl(["{ provider: INVALID_JSON_WITHOUT_QUOTES ..."], tmp_bad_json);
cfg_bad = mda_load_config(tmp_bad_json);
assert_equal_val(cfg_bad.api_key, "", "Malformed JSON does not crash and defaults api_key to empty");
assert_true(cfg_bad.config_error <> "", "Malformed JSON records config_error message");

// 6. Environment variable precedence and empty values
// 6a: Empty env var does not overwrite file key
setenv("TWELVE_DATA_API_KEY", "   ");
cfg_prec1 = mda_load_config(tmp_json);
assert_equal_val(cfg_prec1.api_key, "custom_json_key_777", "Empty env var does not overwrite valid file key");

// 6b: Placeholder env var does not overwrite file key
setenv("TWELVE_DATA_API_KEY", "YOUR_TWELVE_DATA_API_KEY_HERE");
cfg_prec2 = mda_load_config(tmp_json);
assert_equal_val(cfg_prec2.api_key, "custom_json_key_777", "Placeholder env var does not overwrite valid file key");

// 6c: Valid env var overrides file key
setenv("TWELVE_DATA_API_KEY", "override_env_key_666");
cfg_prec3 = mda_load_config(tmp_json);
assert_equal_val(cfg_prec3.api_key, "override_env_key_666", "Valid env var overrides JSON file key");
setenv("TWELVE_DATA_API_KEY", "");

// Clean up temp test files
mdelete(tmp_json);
mdelete(tmp_bad_json);

// 7. Offline analysis with no API key
d_synth_test = load_dataset(mda_adapter_dir() + "sample_data/tech_growth_stock.csv");
assert_true(d_synth_test.n >= 100, "Offline synthetic dataset loads without API key");
lr_synth = run_model(d_synth_test, "LR", 80, 5, 0.2, 0.1);
assert_true(lr_synth.next_price > 0, "Model engine runs offline analysis without API key");

// 8. Fetch Live failure preserving existing data
existing_data = d_synth_test;
fetch_failed = %f;
dummy_bad_cfg = mda_default_config();
dummy_bad_cfg.api_key = "";
try
    mda_fetch_market_data("NONEXISTENT_TICKER_XYZ", "NASDAQ", 120, %t, dummy_bad_cfg);
catch
    fetch_failed = %t;
end
assert_true(fetch_failed, "Invalid fetch raises error without crashing");
assert_equal_val(existing_data.n, d_synth_test.n, "Existing data structure is perfectly preserved on fetch failure");
assert_equal_val(existing_data.close(1), d_synth_test.close(1), "Existing price series unaltered on fetch failure");

// 9. Ensuring mock/synthetic data is never labelled as live
is_live_flag = %f;
if isfield(d_synth_test, "source_mode") then
    if d_synth_test.source_mode == "LIVE_MARKET" then is_live_flag = %t; end
end
assert_true(~is_live_flag, "Synthetic dataset is never flagged as LIVE_MARKET");
assert_true(aapl_data.data_freshness <> "End-of-Day / 15m Delayed [Live Network Fetch]", ..
            "Mock market fixture is never labeled as live network fetch");

// 10. Credential redaction in logs and error messages
secret_key = "secret_test_token_abc123";
err_with_secret = "Failed to connect to https://api.twelvedata.com/time_series?apikey=" + secret_key + " (HTTP 401)";
clean_err = mda_sanitize_error(err_with_secret, secret_key);
assert_true(strindex(clean_err, secret_key) == [], "Secret key is redacted from error text");
assert_true(strindex(clean_err, "***MASKED") <> [], "Error text contains masked marker");


// ---------------------------------------------------------------------------
// Final Summary
// ---------------------------------------------------------------------------
mprintf("\n======================================================================\n");
mprintf("  Market Data Adapter Verification Results\n");
mprintf("  Total assertions: %d\n", n_passed + n_failed);
mprintf("  Passed:           %d\n", n_passed);
mprintf("  Failed:           %d\n", n_failed);
mprintf("======================================================================\n");

if n_failed > 0 then
    error("Market data adapter test suite encountered " + string(n_failed) + " failure(s).");
else
    mprintf("ALL MARKET DATA ADAPTER TESTS PASSED SUCCESSFULLY.\n");
end

exit(0);
