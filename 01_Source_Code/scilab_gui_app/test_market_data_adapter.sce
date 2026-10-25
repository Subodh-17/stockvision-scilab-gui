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


// ---------------------------------------------------------------------------
// Group 5: Local Caching & Cache TTL Verification
// ---------------------------------------------------------------------------
mprintf("\n--- Group 5: Local Caching & Expiration ---\n");

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

// Read cache with 0 TTL (expired)
[cached_expired, is_expired_valid] = mda_read_cache(test_cache_sym, test_cache_exch, 65, -0.01);
assert_true(~is_expired_valid, "Cache read correctly rejects expired payload (TTL <= 0)");


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
