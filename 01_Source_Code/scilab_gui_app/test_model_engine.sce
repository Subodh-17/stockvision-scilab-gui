// test_model_engine.sce -- headless tests for model_engine.sce (no GUI needed).
// Run: scilab-cli -nb -f test_model_engine.sce   (from this folder)

clear; clc;
exec("model_engine.sce", -1);

n_pass = 0; n_fail = 0;

function check(condition, message)
    // Lightweight assertion helper -- keeps this file readable.
    if condition then
        mprintf("PASS: %s\n", message);
    else
        mprintf("FAIL: %s\n", message);
        error("Test failed: " + message);
    end
endfunction

// Test-only fixture helpers for building CSV files.
function s2 = pad2(v)
    if v < 10 then s2 = "0" + string(v); else s2 = string(v); end
endfunction

function s = make_date(base_year, day_offset)
    // day_offset: 0-based day count from Jan 1 of base_year (leap-year table
    // used unconditionally -- fine, this only ever needs to generate
    // plausible-looking test fixtures, not real calendars).
    days_in_month = [31 29 31 30 31 30 31 31 30 31 30 31];
    m = 1; d = day_offset + 1;
    while d > days_in_month(m)
        d = d - days_in_month(m);
        m = m + 1;
    end
    s = string(base_year) + "-" + pad2(m) + "-" + pad2(d);
endfunction

function write_csv(path, lines)
    fd = mopen(path, "w");
    mputl(lines, fd);
    mclose(fd);
endfunction

function lines = make_valid_csv_lines(n_rows)
    // n_rows clean, ascending, mutually-valid OHLCV rows.
    lines = ["Date,Open,High,Low,Close,Volume"];
    for i = 1:n_rows
        base = 100 + i;
        row = make_date(2024, i-1) + "," + string(base) + "," + string(base+1) + "," + ..
              string(base-1) + "," + string(base) + "," + string(1000 + i*10);
        lines = [lines; row];
    end
endfunction

TMP = TMPDIR + "/scilab_gui_app_test_";

// ---------------------------------------------------------------------------
// Test 1: load_dataset on all three bundled sample files
// ---------------------------------------------------------------------------
datasets = ["sample_data/tech_growth_stock.csv", "sample_data/blue_chip_stock.csv", ..
            "sample_data/volatile_stock.csv"];
for i = 1:size(datasets, 2)
    d = load_dataset(datasets(i));
    check(d.n > 0, "load_dataset: " + datasets(i) + " loaded rows > 0");
    check(size(d.close, 1) == d.n, "load_dataset: close vector length matches n");
    check(~or(isnan(d.close)), "load_dataset: no NaN in close prices");
    check(size(d.warnings, 1) == 0, "load_dataset: clean bundled file produces no warnings");
end

// ---------------------------------------------------------------------------
// Test 1b: load_dataset validation on hand-crafted CSV fixtures
// ---------------------------------------------------------------------------
good_lines = make_valid_csv_lines(35);

// -- wrong header --
bad_header = good_lines;
bad_header(1) = "Date,Open,High,Low,Close,Vol";
write_csv(TMP + "bad_header.csv", bad_header);
caught = %f;
try
    load_dataset(TMP + "bad_header.csv");
catch
    caught = %t;
end
check(caught, "load_dataset: wrong column header is rejected with an error");

// -- too few rows --
write_csv(TMP + "too_few.csv", make_valid_csv_lines(5));
caught = %f;
try
    load_dataset(TMP + "too_few.csv");
catch
    caught = %t;
end
check(caught, "load_dataset: file with too few usable rows is rejected");

// -- completely empty file (0 bytes, not even a header) --
fd_empty = mopen(TMP + "empty.csv", "w");
mclose(fd_empty);
caught = %f;
try
    load_dataset(TMP + "empty.csv");
catch
    caught = %t;
end
check(caught, "load_dataset: a completely empty file (0 bytes) is rejected, not crashed on");

// -- header-only file (correct header, zero data rows) --
write_csv(TMP + "header_only.csv", ["Date,Open,High,Low,Close,Volume"]);
caught = %f;
try
    load_dataset(TMP + "header_only.csv");
catch
    caught = %t;
end
check(caught, "load_dataset: a header-only file (zero data rows) is rejected with a clear error");

// -- duplicate date --
dup_lines = good_lines;
dup_lines(3) = dup_lines(2);   // row 2 (index 3 incl. header) now duplicates row 1's date
write_csv(TMP + "dup_date.csv", dup_lines);
caught = %f;
try
    load_dataset(TMP + "dup_date.csv");
catch
    caught = %t;
end
check(caught, "load_dataset: duplicate dates are rejected with an error");

// -- newest-first (descending) order gets auto-sorted, not rejected --
desc_lines = [good_lines(1); good_lines($:-1:2)];
write_csv(TMP + "descending.csv", desc_lines);
d_desc = load_dataset(TMP + "descending.csv");
check(d_desc.n == 35, "load_dataset: descending-order file still loads all 35 rows");
check(size(d_desc.warnings, 1) > 0, "load_dataset: descending-order file produces a warning");
check(d_desc.close(1) < d_desc.close($), ..
      "load_dataset: descending-order file is auto-sorted back to ascending");

// -- bad rows get dropped with a warning, not rejected outright --
messy_lines = good_lines;
messy_lines($+1) = ",,,,,";                                // blank row (empty fields, not a bare empty line)
messy_lines($+1) = "2024-03-01,abc,101,99,100,1000";      // non-numeric Open
messy_lines($+1) = "2024-03-02,100,101,99,100,-50";        // negative volume
messy_lines($+1) = "2024-03-03,100,99,101,100,1000";       // Low > High (impossible)
write_csv(TMP + "messy.csv", messy_lines);
d_messy = load_dataset(TMP + "messy.csv");
check(d_messy.n == 35, "load_dataset: 4 bad rows dropped, 35 good rows survive");
check(size(d_messy.warnings, 1) > 0, "load_dataset: dropped rows produce a warning message");

// -- missing column (only 5 columns -- no Volume) --
missing_col_lines = ["Date,Open,High,Low,Close"; ..
                      "2024-01-01,100,101,99,100"; ..
                      "2024-01-02,100,101,99,100"];
write_csv(TMP + "missing_col.csv", missing_col_lines);
caught = %f;
try
    load_dataset(TMP + "missing_col.csv");
catch
    caught = %t;
end
check(caught, "load_dataset: a CSV missing the Volume column (5 columns instead of 6) is rejected");

// A single impossible date is dropped as a bad row, not fatal.
bad_date_lines = good_lines;
bad_date_lines(5) = "2024-13-45,100,101,99,100,1000";   // invalid month AND day
write_csv(TMP + "bad_dates.csv", bad_date_lines);
d_bd = load_dataset(TMP + "bad_dates.csv");
check(d_bd.n == 34, "load_dataset: a single malformed-date row is dropped, not fatal to the whole file");
check(size(d_bd.warnings, 1) > 0, "load_dataset: dropping a malformed-date row produces a warning");

// Constant prices through the full pipeline: every LR feature has zero
// training std, exercising the sigma==0 guard on every column.
const_lines = ["Date,Open,High,Low,Close,Volume"];
for i = 1:35
    const_lines = [const_lines; make_date(2024, i-1) + ",50,50,50,50,1000"];
end
write_csv(TMP + "constant_price.csv", const_lines);
d_const = load_dataset(TMP + "constant_price.csv");
check(d_const.n == 35, "load_dataset: a constant-price CSV loads cleanly (flat prices are not themselves invalid)");

feat_const = build_lr_features(d_const);
lr_const = fit_linear_regression(feat_const, 0.8);
eval_const = evaluate_model(lr_const);
check(~isnan(eval_const.rmse) & ~isinf(eval_const.rmse), ..
      "fit_linear_regression: a constant-price series (every feature training std = 0) " + ..
      "fits without NaN/Inf, thanks to the sigma==0 guard");
[const_next_lr, const_lo, const_hi] = predict_next_lr(lr_const);
check(abs(const_next_lr - 50) < 1e-6, ..
      "predict_next_lr: a constant-price series correctly predicts that same constant price");

ar_const = fit_ar_model(d_const, 10, 0.8);
eval_ar_const = evaluate_ar_model(ar_const);
check(~isnan(eval_ar_const.rmse) & ~isinf(eval_ar_const.rmse), ..
      "fit_ar_model: the same constant-price series (via the full CSV pipeline this time, not a " + ..
      "hand-built struct) also fits without NaN/Inf");

// ---------------------------------------------------------------------------
// Test 1c: date/number parsing helpers, directly
// ---------------------------------------------------------------------------
check(is_valid_number_string("123.45"), "is_valid_number_string: accepts a normal decimal");
check(is_valid_number_string("-12"), "is_valid_number_string: accepts a negative integer");
check(~is_valid_number_string("12.3.4"), "is_valid_number_string: rejects two decimal points");
check(~is_valid_number_string("12a"), "is_valid_number_string: rejects trailing non-numeric text");
check(~is_valid_number_string(""), "is_valid_number_string: rejects an empty string");

[y1, m1, d1, ok1] = parse_iso_date("2024-02-29");
check(ok1 & y1 == 2024 & m1 == 2 & d1 == 29, "parse_iso_date: accepts a valid leap-year Feb 29");
[y2, m2, d2, ok2] = parse_iso_date("2023-02-29");
check(~ok2, "parse_iso_date: rejects Feb 29 in a non-leap year");
[y3, m3, d3, ok3] = parse_iso_date("2024-13-01");
check(~ok3, "parse_iso_date: rejects month 13");
[y4, m4, d4, ok4] = parse_iso_date("01/02/2024");
check(~ok4, "parse_iso_date: rejects a non-ISO date format");

// ---------------------------------------------------------------------------
// Test 2: LR feature engineering + fit + evaluate + predict, on real bundled data
// ---------------------------------------------------------------------------
data = load_dataset("sample_data/tech_growth_stock.csv");
feat = build_lr_features(data);
check(feat.n_valid > 200, "build_lr_features: enough valid rows survive NaN-dropping");
check(size(feat.X_raw, 2) == 12, "build_lr_features: 12 features built");
check(feat.latest_raw(4) == data.close($), ..
      "build_lr_features: latest_raw Close feature is the TRUE most recent close " + ..
      "(regression test for the [stale last row] next-day-prediction bug)");

lr_model = fit_linear_regression(feat, 0.8);
check(size(lr_model.beta, 1) == 13, "fit_linear_regression: 13 coefficients (12 features + intercept)");

mu_train_check = mean(feat.X_raw(1:lr_model.split_idx, :), "r");
check(and(abs(lr_model.mu - mu_train_check) < 1e-9), ..
      "fit_linear_regression: mu is computed from TRAINING rows only (regression test for data leakage)");

lr_eval = evaluate_model(lr_model);
check(lr_eval.rmse > 0 & lr_eval.rmse < 1e6, "evaluate_model (LR): RMSE in a sane range");
check(lr_eval.r2 > 0.5, "evaluate_model (LR): R^2 > 0.5 on trending synthetic data (sanity check)");
check(~isnan(lr_eval.rmse) & ~isnan(lr_eval.r2), "evaluate_model (LR): no NaN in metrics");
check(~isnan(lr_eval.accuracy_pct) & lr_eval.accuracy_pct >= 0 & lr_eval.accuracy_pct <= 100, ..
      "evaluate_model (LR): Prediction Accuracy %% is a sane 0-100 value");
check(abs(lr_eval.accuracy_pct - (100 - lr_eval.mape)) < 1e-9, ..
      "evaluate_model (LR): Prediction Accuracy %% = 100 - MAPE");

[lr_next, lr_ci_lo, lr_ci_hi] = predict_next_lr(lr_model);
check(lr_next > 0, "predict_next_lr: predicted price is positive");
check(abs(lr_next - data.close($)) / data.close($) < 0.5, ..
      "predict_next_lr: prediction within a plausible range of current price");
check(lr_ci_lo < lr_next & lr_next < lr_ci_hi, ..
      "predict_next_lr: confidence interval brackets the point prediction");

// ---------------------------------------------------------------------------
// Test 3: AR model fit + evaluate + predict, on the same data
// ---------------------------------------------------------------------------
ar_model = fit_ar_model(data, 10, 0.8);
check(size(ar_model.beta, 1) == 11, "fit_ar_model: 11 coefficients (10 lags + intercept)");

train_close_range = data.close(1:ar_model.split_idx + ar_model.p);
check(abs(ar_model.price_min - min(train_close_range)) < 1e-9 & ..
      abs(ar_model.price_max - max(train_close_range)) < 1e-9, ..
      "fit_ar_model: price_min/price_max computed from TRAINING data only (regression test for data leakage)");

ar_eval = evaluate_ar_model(ar_model);
check(ar_eval.rmse > 0, "evaluate_ar_model: RMSE > 0");
check(~isnan(ar_eval.rmse) & ~isnan(ar_eval.r2), "evaluate_ar_model: no NaN in metrics");
check(~isnan(ar_eval.accuracy_pct) & ar_eval.accuracy_pct >= 0 & ar_eval.accuracy_pct <= 100, ..
      "evaluate_ar_model: Prediction Accuracy %% is a sane 0-100 value");

[ar_next, ar_ci_lo, ar_ci_hi] = predict_next_ar(ar_model);
check(ar_next > 0, "predict_next_ar: predicted price is positive");
check(ar_ci_lo < ar_next & ar_next < ar_ci_hi, ..
      "predict_next_ar: confidence interval brackets the point prediction");

// -- AR degenerate case: an all-identical price series must not blow up the
// min-max scaling (price_max - price_min = 0) --
n_flat = 30;
flat_data = struct(); flat_data.close = ones(n_flat, 1) * 50; flat_data.n = n_flat;
ar_flat = fit_ar_model(flat_data, 5, 0.8);
check(~isnan(ar_flat.beta(1)) & ~isinf(ar_flat.beta(1)), ..
      "fit_ar_model: constant price series (degenerate scaling range) does not produce NaN/Inf");
[flat_next, flat_lo, flat_hi] = predict_next_ar(ar_flat);
check(abs(flat_next - 50) < 1e-6, ..
      "predict_next_ar: constant price series correctly predicts that same constant price");

// ---------------------------------------------------------------------------
// Test 3b: evaluate_model division-by-zero guards (MAPE, R^2), unit-level
// ---------------------------------------------------------------------------
deg1 = struct(); deg1.beta = [5; 0]; deg1.X_test = zeros(3,1); deg1.y_test = [5;5;5];
deg1_eval = evaluate_model(deg1);
check(deg1_eval.r2 == 1, ..
      "evaluate_model: constant test target with a PERFECT trivial fit -> R^2 = 1, not NaN/crash");
check(~isnan(deg1_eval.mape), "evaluate_model: MAPE is well-defined when actuals are nonzero");

deg2 = struct(); deg2.beta = [0; 0]; deg2.X_test = zeros(2,1); deg2.y_test = [0; 0];
deg2_eval = evaluate_model(deg2);
check(isnan(deg2_eval.mape), ..
      "evaluate_model: MAPE is NaN (not Inf/crash) when every test actual price is zero");
check(deg2_eval.r2 == 1, "evaluate_model: zero-variance zero-actual test set with a perfect fit -> R^2 = 1");
check(isnan(deg2_eval.accuracy_pct), "evaluate_model: Prediction Accuracy is NaN when MAPE is undefined");

deg4 = struct(); deg4.beta = [0; 0]; deg4.X_test = zeros(2,1); deg4.y_test = [1; 1];   // pred=0, actual=1 -> 100% error
deg4_eval = evaluate_model(deg4);
check(deg4_eval.accuracy_pct == 0, ..
      "evaluate_model: Prediction Accuracy is floored at 0%% (not negative) when MAPE exceeds 100%%");

deg3 = struct(); deg3.beta = [1; 0]; deg3.X_test = zeros(2,1); deg3.y_test = [5; 5];
deg3_eval = evaluate_model(deg3);
check(isnan(deg3_eval.r2), ..
      "evaluate_model: constant test target with an IMPERFECT fit -> R^2 is NaN (undefined), " + ..
      "not a division-by-zero crash");

// ---------------------------------------------------------------------------
// Test 4: signal generation -- all three branches, plus exact-threshold edges
// ---------------------------------------------------------------------------
sig = generate_signal(100, 103, 0.5, -0.5);
check(sig.action == "BUY", "generate_signal: +3% change -> BUY");

sig = generate_signal(100, 97, 0.5, -0.5);
check(sig.action == "SELL", "generate_signal: -3% change -> SELL");

sig = generate_signal(100, 100.1, 0.5, -0.5);
check(sig.action == "HOLD", "generate_signal: +0.1% change (inside band) -> HOLD");

sig = generate_signal(100, 100.5, 0.5, -0.5);
check(sig.action == "BUY", "generate_signal: exactly at +0.5% threshold -> BUY (inclusive)");

// ---------------------------------------------------------------------------
// Test 5: moving_average helper
// ---------------------------------------------------------------------------
series = [1;2;3;4;5;6;7;8;9;10];
ma3 = moving_average(series, 3);
check(isnan(ma3(1)) & isnan(ma3(2)), "moving_average: leading NaNs before window fills (no history given)");
check(ma3(3) == 2, "moving_average: MA(3) at index 3 = mean(1,2,3) = 2");
check(ma3($) == 9, "moving_average: MA(3) at last index = mean(8,9,10) = 9");

hist = [100; 101; 102];
series2 = [103; 104; 105; 106; 107];
ma2 = moving_average(series2, 3, hist);
check(~isnan(ma2(1)), "moving_average: with history, the FIRST point is no longer NaN " + ..
      "(regression test for the [MA blank at start of test period] bug)");
check(abs(ma2(1) - mean([101;102;103])) < 1e-9, ..
      "moving_average: first point with history correctly uses the last 2 history values");
check(abs(ma2($) - mean([105;106;107])) < 1e-9, ..
      "moving_average: later points match plain (no-history) behavior once the window is full");

// ---------------------------------------------------------------------------
// Test 6: all bundled datasets fit cleanly
// ---------------------------------------------------------------------------
for i = 1:size(datasets, 2)
    d = load_dataset(datasets(i));
    f = build_lr_features(d);
    m = fit_linear_regression(f, 0.8);
    e = evaluate_model(m);
    check(~isnan(e.rmse), "cross-dataset check: " + datasets(i) + " LR fits without NaN");

    am = fit_ar_model(d, 10, 0.8);
    ae = evaluate_ar_model(am);
    check(~isnan(ae.rmse), "cross-dataset check: " + datasets(i) + " AR fits without NaN");
end

// ---------------------------------------------------------------------------
// Test 6b: extreme volatility at the fitting level (distinct from the
// backtest stress test in Test 7).
// ---------------------------------------------------------------------------
n_wild = 40;
idx_wild = (1:n_wild)';
wild_close = 500 + 480*sin(idx_wild*1.3);   // oscillates roughly between 20 and 980, always positive
wild_data = struct();
wild_data.close = wild_close; wild_data.open = wild_close;
wild_data.high = wild_close*1.02; wild_data.low = wild_close*0.98;
wild_data.volume = ones(n_wild,1)*10000;
wild_data.n = n_wild;

wild_feat = build_lr_features(wild_data);
wild_lr = fit_linear_regression(wild_feat, 0.8);
wild_lr_eval = evaluate_model(wild_lr);
check(~isnan(wild_lr_eval.rmse) & ~isinf(wild_lr_eval.rmse), ..
      "fit_linear_regression: an extremely volatile synthetic series (large, rapid swings) " + ..
      "fits without NaN/Inf");

wild_ar = fit_ar_model(wild_data, 10, 0.8);
wild_ar_eval = evaluate_ar_model(wild_ar);
check(~isnan(wild_ar_eval.rmse) & ~isinf(wild_ar_eval.rmse), ..
      "fit_ar_model: the same extremely volatile synthetic series fits without NaN/Inf");

// ---------------------------------------------------------------------------
// Test 7: run_backtest -- hand-verified scenarios (one-day execution lag).
// ---------------------------------------------------------------------------

// 7a. A SELL the day BEFORE a crash avoids it; a signal on the crash day
// itself must not (direct test of the execution lag).
actual_avoid = [100; 105; 105; 80];
pred_avoid   = [%nan; 104; 95; 70];   // day2: +4%->BUY. day3: -9.5%->SELL (one day before the crash)
bt = run_backtest(actual_avoid, pred_avoid, 0.5, -0.5, 1000);
check(abs(bt.strategy_final - 1000) < 1e-6, ..
      "run_backtest: a SELL signal one day ahead of a crash avoids it entirely -- ends flat at 1000");
check(abs(bt.buyhold_final - 800) < 1e-6, ..
      "run_backtest: buy-and-hold takes the full crash -- ends at exactly 800");
check(bt.strategy_final > bt.buyhold_final, ..
      "run_backtest: strategy beats buy-and-hold when it sells one day ahead of a drop");
check(bt.n_trades == 2, "run_backtest: exactly 2 trades (one BUY, one SELL) in the avoidance scenario");
check(bt.n_completed_trades == 1, "run_backtest: exactly 1 completed round-trip trade");
check(bt.win_rate_pct == 0, ..
      "run_backtest: the one completed trade had exactly 0% P&L -- not counted as a win");

// 7a-lag. The SAME crash, but the SELL signal only fires ON the crash day
// (no one-day head start) -- with the execution lag now enforced, the
// strategy can no longer dodge a move it only learns about as it happens.
actual_crash = [100; 105; 80];
pred_crash   = [%nan; 104; 95];
bt_lag = run_backtest(actual_crash, pred_crash, 0.5, -0.5, 1000);
check(bt_lag.strategy_final < bt.strategy_final, ..
      "run_backtest: a same-day signal can no longer capture a return that already happened " + ..
      "(regression test for the look-ahead/timing-bias fix)");
check(abs(bt_lag.strategy_final - 1000*(105/105)*(1 - 0.238095238)) < 1e-4, ..
      "run_backtest: same-day-signal scenario matches the exact lagged-execution arithmetic");

// 7b. A BUY on day 2 with the entry lag misses the day1->day2 move, so the
// strategy ends strictly below buy-and-hold by exactly that missed leg.
actual_up = [100; 102; 104; 106; 108];
pred_up   = [%nan; 103; 105; 107; 109];   // consistently signals BUY, never SELL
bt2 = run_backtest(actual_up, pred_up, 0.5, -0.5, 1000);
expected_strategy_final = 1000 * actual_up($) / actual_up(2);
check(abs(bt2.strategy_final - expected_strategy_final) < 1e-6, ..
      "run_backtest: entry lag means the strategy tracks price growth starting AFTER entry, exactly");
check(bt2.strategy_final < bt2.buyhold_final, ..
      "run_backtest: entry lag means staying invested from day 2 still slightly underperforms " + ..
      "true buy-and-hold (which was invested from day 1)");

// 7c. All predictions inside the HOLD band -> never enters the market ->
// strategy value stays flat at starting capital regardless of what the
// actual (possibly volatile) market does.
actual_choppy = [100; 90; 110; 95; 105];
pred_choppy   = [%nan; 100; 90; 110; 95];   // always exactly = previous actual -> 0% change -> HOLD
bt3 = run_backtest(actual_choppy, pred_choppy, 0.5, -0.5, 1000);
check(bt3.strategy_final == 1000, "run_backtest: all-HOLD signals -> strategy never enters, stays flat");
check(bt3.n_trades == 0, "run_backtest: all-HOLD signals -> zero trades");
check(bt3.buyhold_final <> 1000, "run_backtest: buy-and-hold still moves with the (choppy) market");
check(isnan(bt3.win_rate_pct), "run_backtest: win rate is NaN (undefined), not 0, with zero completed trades");

// 7d. Edge case: a single-row series can't generate any signal (need i-1) --
// must not crash, and must just return the starting capital unchanged.
bt4 = run_backtest([100], [100], 0.5, -0.5, 1000);
check(bt4.strategy_final == 1000 & bt4.buyhold_final == 1000, ..
      "run_backtest: single-row input does not crash, returns starting capital unchanged");
check(bt4.n_trades == 0, "run_backtest: single-row input -> zero trades");

// 7e. Sanity check on a real bundled dataset + real fitted model (not just
// hand-crafted numbers) -- must run without error and produce finite results.
data = load_dataset("sample_data/tech_growth_stock.csv");
feat = build_lr_features(data);
lr_model = fit_linear_regression(feat, 0.8);
lr_eval = evaluate_model(lr_model);
bt5 = run_backtest(lr_model.y_test, lr_eval.y_pred, 0.5, -0.5, 100000);
check(~isnan(bt5.strategy_final) & ~isnan(bt5.buyhold_final), ..
      "run_backtest: real fitted-model backtest on bundled data produces finite results");
check(bt5.strategy_final > 0, "run_backtest: real backtest strategy value stays positive");
check(bt5.max_drawdown_pct >= 0 & bt5.max_drawdown_pct <= 100, ..
      "run_backtest: max drawdown is a sane percentage");

// 7f. Transaction costs must actually reduce the strategy's ending value.
bt_cost = run_backtest(actual_avoid, pred_avoid, 0.5, -0.5, 1000, 1, 0);   // 1% cost per trade
check(abs(bt_cost.strategy_final - 980.1) < 1e-6, ..
      "run_backtest: 1%% transaction cost on 2 trades matches the exact expected arithmetic");
check(bt_cost.strategy_final < bt.strategy_final, ..
      "run_backtest: transaction costs reduce the ending value versus the zero-cost run");
check(bt_cost.strategy_final > bt.buyhold_final, ..
      "run_backtest: a modest transaction cost does not erase the whole crash-avoidance edge");
check(abs(bt_cost.starting_capital - 1000) < 1e-9, ..
      "run_backtest: the returned struct carries the starting capital it was actually given");

// 7f2. Slippage must reduce value on its own and add to transaction cost.
bt_slip = run_backtest(actual_avoid, pred_avoid, 0.5, -0.5, 1000, 0, 1);   // 0%% txn cost, 1%% slippage only
check(abs(bt_slip.strategy_final - 980.1) < 1e-6, ..
      "run_backtest: slippage ALONE (zero transaction cost) reduces the ending value identically to " + ..
      "an equivalent 1%% transaction cost -- confirms slippage_pct is genuinely applied, not just accepted");

bt_both = run_backtest(actual_avoid, pred_avoid, 0.5, -0.5, 1000, 0.5, 0.5);   // 0.5%%+0.5%% = 1%% combined
check(abs(bt_both.strategy_final - 980.1) < 1e-6, ..
      "run_backtest: transaction cost and slippage combine additively (0.5%%+0.5%%), matching the " + ..
      "single-1%%-cost result exactly");

// 7g. Sharpe/volatility/drawdown against independently derived values:
// strategy_value is checked against a hand-derived sequence, then Sharpe and
// volatility are recomputed in the test with Scilab's own mean/stdev.
actual_risk = [100; 100; 110; 99; 108.9];             // day4->day5 is +10% (108.9 = 99*1.1 exactly)
pred_risk   = [%nan; 102; 102; 112.2; 100.98];         // always +2% vs prior actual -> always BUY, never SELL
bt_risk = run_backtest(actual_risk, pred_risk, 0.5, -0.5, 1000);

expected_sv = [1000; 1000; 1100; 990; 1089];
check(and(abs(bt_risk.strategy_value - expected_sv) < 1e-6), ..
      "run_backtest: hand-derived strategy_value sequence matches exactly (basis for the risk-metric checks below)");

expected_dd = (1100 - 990) / 1100 * 100;   // peak at day3 (1100), trough at day4 (990)
check(abs(bt_risk.max_drawdown_pct - expected_dd) < 1e-6, ..
      "run_backtest: max drawdown matches the hand-computed peak-to-trough decline");

expected_dr = [(1000-1000)/1000; (1100-1000)/1000; (990-1100)/1100; (1089-990)/990];
expected_sharpe = mean(expected_dr) / stdev(expected_dr) * sqrt(252);
expected_vol = stdev(expected_dr) * sqrt(252) * 100;
check(abs(bt_risk.sharpe_ratio - expected_sharpe) < 1e-6, ..
      "run_backtest: Sharpe ratio matches an independently-recomputed value from the same known returns");
check(abs(bt_risk.volatility_pct_annualized - expected_vol) < 1e-6, ..
      "run_backtest: annualized volatility matches an independently-recomputed value");

// 7h. Win rate verified against a hand-built scenario with a KNOWN mix of
// winning and losing trades: 2 profitable round-trips + 1 losing one.
actual_wr = [100; 90; 130; 130; 150; 150; 80; 100];
pred_wr   = [%nan; 110; 80; 145; 120; 165; 140; 80.2];
bt_wr = run_backtest(actual_wr, pred_wr, 0.5, -0.5, 1000);
check(bt_wr.n_completed_trades == 3, "run_backtest: win-rate scenario produces exactly 3 completed round-trip trades");
check(abs(bt_wr.win_rate_pct - 2/3*100) < 1e-6, ..
      "run_backtest: win rate matches the hand-verified 2-wins-out-of-3 result (66.67%%)");

// 7i. Edge case: constant prices throughout -- zero variance in returns
// must produce a defined (NaN, not crash/Inf) Sharpe ratio and exactly
// zero volatility and drawdown.
actual_flat = ones(6,1) * 100;
pred_flat = [%nan; ones(5,1)*100];   // 0%% predicted change every day -> always HOLD
bt_flat = run_backtest(actual_flat, pred_flat, 0.5, -0.5, 1000);
check(bt_flat.strategy_final == 1000 & bt_flat.buyhold_final == 1000, ..
      "run_backtest: constant price series -> both strategy and buy&hold stay exactly at starting capital");
check(bt_flat.n_trades == 0, "run_backtest: constant price series with 0%% predicted change every day never trades");
check(isnan(bt_flat.sharpe_ratio), ..
      "run_backtest: zero-variance daily returns -> Sharpe is NaN (undefined), not Inf/crash");
check(bt_flat.volatility_pct_annualized == 0, "run_backtest: constant price series has exactly 0%% volatility");
check(bt_flat.max_drawdown_pct == 0, "run_backtest: constant price series has exactly 0%% drawdown");

// 7j. Edge case: the smallest input that can generate exactly one signal
// (n=2) -- must not crash, and daily-return-based metrics (needing >=2
// points) must come back as a defined NaN rather than erroring.
bt_n2 = run_backtest([100; 105], [%nan; 110], 0.5, -0.5, 1000);
check(~isnan(bt_n2.strategy_final), "run_backtest: 2-row input does not crash and produces a finite result");
check(bt_n2.n_trades == 1 & bt_n2.n_completed_trades == 0, ..
      "run_backtest: 2-row input can open a position but cannot complete a round trip yet");
check(isnan(bt_n2.sharpe_ratio) & isnan(bt_n2.win_rate_pct), ..
      "run_backtest: 2-row input has too few points for Sharpe/win-rate -- NaN, not a crash");

// 7k. NaN in y_actual must be rejected (it would corrupt the return chain);
// NaN in y_pred just fails both thresholds and falls through to HOLD.
caught = %f;
try
    run_backtest([100; %nan; 110], [%nan; 105; 108], 0.5, -0.5, 1000);
catch
    caught = %t;
end
check(caught, "run_backtest: a NaN in y_actual (e.g. an uncleaned data gap) is rejected with a clear " + ..
      "error instead of silently corrupting every later day");

bt_gap = run_backtest([100; 105; 110; 108; 115], [%nan; 106; %nan; 109; 116], 0.5, -0.5, 1000);
check(~isnan(bt_gap.strategy_final) & ~isinf(bt_gap.strategy_final), ..
      "run_backtest: a NaN in y_pred for a single day (a missing prediction) degrades gracefully " + ..
      "to a HOLD that day, rather than crashing or corrupting the rest of the run");

// 7l. Extreme swings (+100%, -75%, +500%, ...) must stay finite with a sane
// drawdown. A robustness check, not a precision check (7g/7h cover precision).
actual_wild = [100; 200; 50; 300; 20; 250; 15];
pred_wild   = [%nan; 150; 300; 75; 450; 30; 375];   // always 50%% above prior actual -> always BUY
bt_wild = run_backtest(actual_wild, pred_wild, 0.5, -0.5, 1000);
check(~isnan(bt_wild.strategy_final) & ~isinf(bt_wild.strategy_final) & bt_wild.strategy_final > 0, ..
      "run_backtest: extreme alternating price swings stay finite and positive (no NaN/Inf blowup)");
check(bt_wild.max_drawdown_pct >= 0 & bt_wild.max_drawdown_pct <= 100, ..
      "run_backtest: max drawdown stays within [0,100] even under extreme volatility");
check(isnan(bt_wild.sharpe_ratio) | ~isinf(bt_wild.sharpe_ratio), ..
      "run_backtest: Sharpe ratio under extreme volatility is either a finite number or NaN, never Inf");
check(~isnan(bt_wild.volatility_pct_annualized) & ~isinf(bt_wild.volatility_pct_annualized), ..
      "run_backtest: annualized volatility under extreme swings is a large but finite number");

// ---------------------------------------------------------------------------
// Test 8: walk_forward_validate -- multi-fold, leakage-safe evaluation
// ---------------------------------------------------------------------------
wf_lr = walk_forward_validate(data, "LR", 3, 10);
check(wf_lr.n_folds == 3, "walk_forward_validate (LR): runs the requested number of folds");
check(size(wf_lr.fold_rmse, 1) == 3, "walk_forward_validate (LR): one RMSE per fold");
check(~isnan(wf_lr.mean_rmse) & wf_lr.mean_rmse > 0, ..
      "walk_forward_validate (LR): mean RMSE across folds is a sane positive number");

// Fold boundaries: each test window starts where the previous one ended
// (no gap/overlap) and the folds reach the end of the data.
for f = 2:3
    check(wf_lr.fold_train_end(f) == wf_lr.fold_test_end(f-1), ..
          "walk_forward_validate (LR): fold " + string(f) + " training window ends exactly " + ..
          "where fold " + string(f-1) + " test window ended -- sequential, non-overlapping folds");
end
check(wf_lr.fold_test_end($) == wf_lr.n_total, ..
      "walk_forward_validate (LR): the last fold test window reaches the end of the usable data " + ..
      "(the remainder-absorption rule)");
check(wf_lr.fold_train_end(1) == wf_lr.min_train, ..
      "walk_forward_validate (LR): the first fold training window is exactly the computed min_train");
for f = 1:3
    check(wf_lr.fold_test_end(f) > wf_lr.fold_train_end(f), ..
          "walk_forward_validate (LR): fold " + string(f) + " has a non-empty test window");
end

// Independent recomputation of fold 1's RMSE, written without calling the
// function's internals, so an arithmetic bug cannot hide.
feat_wf = build_lr_features(data);
train_end_1 = wf_lr.fold_train_end(1); test_end_1 = wf_lr.fold_test_end(1);
Xtr1 = feat_wf.X_raw(1:train_end_1, :); ytr1 = feat_wf.y(1:train_end_1);
Xte1 = feat_wf.X_raw(train_end_1+1:test_end_1, :); yte1 = feat_wf.y(train_end_1+1:test_end_1);
mu1 = mean(Xtr1, "r"); sigma1 = stdev(Xtr1, "r"); sigma1(sigma1 == 0) = 1;
Xtr1_s = (Xtr1 - repmat(mu1, size(Xtr1,1), 1)) ./ repmat(sigma1, size(Xtr1,1), 1);
Xte1_s = (Xte1 - repmat(mu1, size(Xte1,1), 1)) ./ repmat(sigma1, size(Xte1,1), 1);
beta1 = [ones(size(Xtr1_s,1),1), Xtr1_s] \ ytr1;
pred1 = [ones(size(Xte1_s,1),1), Xte1_s] * beta1;
expected_fold1_rmse = sqrt(mean((yte1 - pred1).^2));
check(abs(wf_lr.fold_rmse(1) - expected_fold1_rmse) < 1e-6, ..
      "walk_forward_validate (LR): fold 1 RMSE matches an independently-recomputed value " + ..
      "(same slice/scale/fit sequence, computed separately right here in the test)");

wf_ar = walk_forward_validate(data, "AR", 3, 10);
check(wf_ar.n_folds == 3, "walk_forward_validate (AR): runs the requested number of folds");
check(~isnan(wf_ar.mean_rmse) & wf_ar.mean_rmse > 0, ..
      "walk_forward_validate (AR): mean RMSE across folds is a sane positive number");
check(wf_ar.fold_test_end($) == wf_ar.n_total, ..
      "walk_forward_validate (AR): the last fold test window also reaches the end of the usable data");

// 8a. Known-truth check: a noise-free linear series (target = close + 2) is
// reproducible exactly by a linear model, so RMSE ~ 0 and R^2 ~ 1 in every fold.
// Anything else would point to leakage or a slicing bug.
n_linear = 100;
idx_lin = (1:n_linear)';
linear_close = 100 + 2*idx_lin;   // perfectly linear, zero noise
linear_data = struct();
linear_data.close = linear_close; linear_data.open = linear_close;
linear_data.high = linear_close + 1; linear_data.low = linear_close - 1;
linear_data.volume = ones(n_linear,1) * 1000;
linear_data.n = n_linear;

wf_linear_lr = walk_forward_validate(linear_data, "LR", 3, 10);
check(wf_linear_lr.mean_rmse < 1e-6, ..
      "walk_forward_validate (LR): a perfectly linear, noise-free price series is fit essentially " + ..
      "exactly in every fold (RMSE ~ 0) -- verified against a KNOWN, analytically-expected result");
check(wf_linear_lr.mean_r2 > 0.999999, ..
      "walk_forward_validate (LR): R^2 is essentially 1 on the same noise-free linear series");

wf_linear_ar = walk_forward_validate(linear_data, "AR", 3, 10);
check(wf_linear_ar.mean_rmse < 1e-6, ..
      "walk_forward_validate (AR): the same perfectly linear series is also fit essentially exactly");
check(wf_linear_ar.mean_r2 > 0.999999, ..
      "walk_forward_validate (AR): R^2 is essentially 1 for AR on the same noise-free series too");

// ---------------------------------------------------------------------------
// Test 9: minimum-length boundary checks (build_lr_features / fit_ar_model)
// ---------------------------------------------------------------------------
// Exactly at the boundary (n=30 -> 20 LR rows / 20 AR samples at p=10) must succeed.
n_boundary = 30;
boundary_data = struct();
boundary_data.close = 100 + (1:n_boundary)';
boundary_data.open = boundary_data.close; boundary_data.high = boundary_data.close + 1;
boundary_data.low = boundary_data.close - 1; boundary_data.volume = ones(n_boundary,1)*1000;
boundary_data.n = n_boundary;
feat_boundary = build_lr_features(boundary_data);
check(feat_boundary.n_valid == 20, "build_lr_features: exactly-at-minimum dataset yields exactly 20 valid rows");
ar_boundary = fit_ar_model(boundary_data, 10, 0.8);
check(size(ar_boundary.beta,1) == 11, "fit_ar_model: exactly-at-minimum dataset fits without error");

// One row short of the boundary must be rejected with a clear error.
under_data = struct();
under_data.close = 100 + (1:29)'; under_data.open = under_data.close;
under_data.high = under_data.close+1; under_data.low = under_data.close-1;
under_data.volume = ones(29,1)*1000; under_data.n = 29;
caught = %f;
try
    build_lr_features(under_data);
catch
    caught = %t;
end
check(caught, "build_lr_features: one row under the minimum is rejected with an error");

// ---------------------------------------------------------------------------
// Test 10: Exponential Smoothing (Holt's linear trend method)
// ---------------------------------------------------------------------------
ES_ALPHA_T = 0.3; ES_BETA_T = 0.1;

es_model = fit_exponential_smoothing(data, 0.8, ES_ALPHA_T, ES_BETA_T);
es_eval = evaluate_es_model(es_model);
check(~isnan(es_eval.rmse) & es_eval.rmse >= 0, ..
      "fit_exponential_smoothing: RMSE on bundled data is a sane non-negative number");
check(size(es_model.y_test, 1) == data.n - es_model.split_idx, ..
      "fit_exponential_smoothing: test-set length matches n - split_idx");
[es_next, es_ci_lo, es_ci_hi] = predict_next_es(es_model);
check(~isnan(es_next) & es_next > 0, ..
      "predict_next_es: next-day forecast is a sane positive price");
check(es_ci_lo <= es_next & es_next <= es_ci_hi, ..
      "predict_next_es: point forecast falls inside its own uncertainty band");

// -- invalid alpha/beta are rejected, not silently clamped or ignored --
caught = %f;
try
    fit_exponential_smoothing(data, 0.8, 0, 0.1);   // alpha=0 is out of (0,1]
catch
    caught = %t;
end
check(caught, "fit_exponential_smoothing: alpha=0 (out of the valid (0,1] range) is rejected");

caught = %f;
try
    fit_exponential_smoothing(data, 0.8, 1.5, 0.1);   // alpha>1
catch
    caught = %t;
end
check(caught, "fit_exponential_smoothing: alpha=1.5 (out of the valid (0,1] range) is rejected");

caught = %f;
try
    fit_exponential_smoothing(data, 0.8, 0.3, -0.1);   // beta<0
catch
    caught = %t;
end
check(caught, "fit_exponential_smoothing: beta=-0.1 (out of the valid [0,1] range) is rejected");

// Known-result check: on a noise-free linear series Holt locks onto the true
// level/trend after its first forecast, so RMSE ~ 0 for any alpha, beta.
es_linear = fit_exponential_smoothing(linear_data, 0.8, ES_ALPHA_T, ES_BETA_T);
es_linear_eval = evaluate_es_model(es_linear);
check(es_linear_eval.rmse < 1e-6, ..
      "fit_exponential_smoothing: a perfectly linear, noise-free price series is fit " + ..
      "essentially exactly (RMSE ~ 0) -- verified against a KNOWN, analytically-expected result");
check(es_linear_eval.r2 > 0.999999, ..
      "fit_exponential_smoothing: R^2 is essentially 1 on the same noise-free linear series");
[es_lin_next, es_lin_lo, es_lin_hi] = predict_next_es(es_linear);
expected_next_linear = linear_data.close($) + 2;   // the series is close(i) = 100 + 2*i
check(abs(es_lin_next - expected_next_linear) < 1e-6, ..
      "predict_next_es: next-day forecast on the noise-free linear series matches the " + ..
      "analytically-known next value exactly");

// -- walk_forward_validate_es: same fold-boundary contract as walk_forward_validate --
wf_es = walk_forward_validate_es(data, 3, ES_ALPHA_T, ES_BETA_T);
check(wf_es.n_folds == 3, "walk_forward_validate_es: runs the requested number of folds");
check(~isnan(wf_es.mean_rmse) & wf_es.mean_rmse >= 0, ..
      "walk_forward_validate_es: mean RMSE across folds is a sane non-negative number");
check(wf_es.fold_test_end($) == wf_es.n_total, ..
      "walk_forward_validate_es: the last fold test window reaches the end of the usable data");
for f = 2:3
    check(wf_es.fold_train_end(f) == wf_es.fold_test_end(f-1), ..
          "walk_forward_validate_es: fold " + string(f) + " training window ends exactly " + ..
          "where fold " + string(f-1) + " test window ended -- sequential, non-overlapping folds");
end

wf_es_linear = walk_forward_validate_es(linear_data, 3, ES_ALPHA_T, ES_BETA_T);
check(wf_es_linear.mean_rmse < 1e-6, ..
      "walk_forward_validate_es: the noise-free linear series is fit essentially exactly " + ..
      "in every fold too (RMSE ~ 0)");

// -- holt_recursion internals, directly: a simple 4-point hand-traceable
// series, checked against hand-computed level/trend/forecast values. --
hand_close = [10; 12; 15; 19];   // deltas: 2, 3, 4 (accelerating, NOT linear --
                                  // exercises real alpha/beta blending, unlike
                                  // the noise-free-linear fixture above where
                                  // alpha/beta stop mattering after step 1)
[hL, hT, hF] = holt_recursion(hand_close, 0.5, 0.5);
// L(1)=10, T(1)=12-10=2
check(abs(hL(1) - 10) < 1e-10 & abs(hT(1) - 2) < 1e-10, ..
      "holt_recursion: initial level/trend seed matches close(1) and close(2)-close(1) exactly");
// fcst(2) = L(1)+T(1) = 12; L(2) = 0.5*12 + 0.5*12 = 12; T(2) = 0.5*(12-10)+0.5*2 = 2
check(abs(hF(2) - 12) < 1e-10, "holt_recursion: fcst(2) matches the hand-computed value exactly");
check(abs(hL(2) - 12) < 1e-10 & abs(hT(2) - 2) < 1e-10, ..
      "holt_recursion: L(2)/T(2) match the hand-computed values exactly");
// fcst(3) = L(2)+T(2) = 14; L(3) = 0.5*15 + 0.5*14 = 14.5; T(3) = 0.5*(14.5-12)+0.5*2 = 2.25
check(abs(hF(3) - 14) < 1e-10, "holt_recursion: fcst(3) matches the hand-computed value exactly");
check(abs(hL(3) - 14.5) < 1e-10 & abs(hT(3) - 2.25) < 1e-10, ..
      "holt_recursion: L(3)/T(3) match the hand-computed values exactly");


// ===========================================================================
// V2 tests: common evaluation window, baseline, comparison, rigor
// ===========================================================================
function d = make_data_from_close(c)
    // Minimal valid data struct from a close-price column.
    n = size(c, 1);
    d = struct();
    d.close = c; d.open = c; d.high = c + 1; d.low = c - 1; d.volume = 1000 * ones(n, 1);
    d.dates = repmat("", n, 1);
    for i = 1:n; d.dates(i) = make_date(2024, i - 1); end
    d.n = n; d.warnings = repmat("", 0, 1);
endfunction


function c = wiggle_series(n)
    // Deterministic pseudo-random-walk-like series (no RNG, reproducible).
    c = zeros(n, 1); c(1) = 100;
    for i = 2:n
        c(i) = c(i-1) + 0.8 * sin(i * 1.7) + 0.5 * cos(i * 0.37) + 0.05;
    end
endfunction

AR_P = 10; ES_A = 0.3; ES_B = 0.1;
real_data = load_dataset("sample_data/tech_growth_stock.csv");
nR = real_data.n;
split_cal = round(nR * 0.8);

// ---------------------------------------------------------------------------
// Test 10: data-quality counters, ordering and train/test row counts
// ---------------------------------------------------------------------------
q = real_data.quality;
check(q.rows == nR & q.raw_rows == nR & q.dropped == 0 & q.missing == 0 & q.duplicates == 0, ..
      "quality: clean bundled file reports 0 dropped, 0 missing, 0 duplicates");
check(q.was_chronological, "quality: bundled file is reported as chronological");

mess = make_valid_csv_lines(40);
mess(5) = "2024-01-05,,106,104,105,1050";            // missing Open
mess(9) = "2024-01-09,110,100,108,109,1090";         // High < Low
write_csv(TMP + "mess_q.csv", mess);
dm = load_dataset(TMP + "mess_q.csv");
check(dm.quality.missing == 1 & dm.quality.invalid_ohlc == 1 & dm.quality.dropped == 2 & dm.n == 38, ..
      "quality: 1 missing-value row and 1 impossible-OHLC row are counted separately and dropped");

rev = make_valid_csv_lines(40);
rev = [rev(1); rev($:-1:2)];
write_csv(TMP + "reversed_q.csv", rev);
dr = load_dataset(TMP + "reversed_q.csv");
check(~dr.quality.was_chronological & and(dr.close(2:$) > dr.close(1:$-1)), ..
      "quality: a newest-first file is flagged non-chronological and sorted ascending");

dq = data_quality_summary(real_data, 0.8);
check(dq.train_rows + dq.test_rows == nR & dq.train_rows == split_cal, ..
      "quality: train + test rows add up to the dataset size");
check(dq.train_last == real_data.dates(split_cal) & dq.test_first == real_data.dates(split_cal + 1), ..
      "quality: train ends and test starts on consecutive dates (no overlap)");

// ---------------------------------------------------------------------------
// Test 11: every model uses the SAME test window
// ---------------------------------------------------------------------------
keys = ["NAIVE", "LR", "AR", "ES"];
runs = list();
for i = 1:4
    runs($+1) = run_model(real_data, keys(i), split_cal, AR_P, ES_A, ES_B);
end
want_true = real_data.close(split_cal+1:nR);
for i = 1:4
    check(and(runs(i).test_idx == (split_cal+1:nR)') & runs(i).n_test == nR - split_cal, ..
          keys(i) + ": test window is rows split+1..n (identical for all models)");
    check(max(abs(runs(i).y_true - want_true)) < 1e-9, keys(i) + ": targets equal the actual test closes");
    check(max(abs(runs(i).y_prev - real_data.close(split_cal:nR-1))) < 1e-9, ..
          keys(i) + ": previous-close vector is the close one day before each target");
    check(size(runs(i).y_pred, 1) == size(runs(i).y_true, 1) & ~or(isnan(runs(i).y_pred)) & ~or(isinf(runs(i).y_pred)), ..
          keys(i) + ": prediction dimensions match the test window and are finite");
end
check(runs(2).n_train == split_cal - 10 & runs(2).model.split_idx + 10 == split_cal, ..
      "LR: training samples = training rows minus the 10-row feature warm-up");
check(runs(3).n_train == split_cal - AR_P, "AR: training samples = training rows - lookback");

// ---------------------------------------------------------------------------
// Test 12: no look-ahead -- changing FUTURE prices cannot change earlier forecasts
// ---------------------------------------------------------------------------
k = split_cal + 25;                                    // perturb everything after row k
pert = real_data;
pert.close(k+1:$) = pert.close(k+1:$) * 1.7;
pert.open(k+1:$) = pert.open(k+1:$) * 1.7; pert.high(k+1:$) = pert.high(k+1:$) * 1.7;
pert.low(k+1:$) = pert.low(k+1:$) * 1.7;
for i = 1:4
    a = run_model(real_data, keys(i), split_cal, AR_P, ES_A, ES_B);
    b = run_model(pert, keys(i), split_cal, AR_P, ES_A, ES_B);
    m_ = k - split_cal;                                  // forecasts for targets split+1..k
    check(max(abs(a.y_pred(1:m_) - b.y_pred(1:m_))) < 1e-9, ..
          keys(i) + ": forecasts for days <= k are unchanged when prices after k change (no look-ahead)");
end

// Truncated data (what each walk-forward fold sees) gives the same forecasts.
cut_d = slice_data(real_data, k);
for i = 1:4
    a = run_model(real_data, keys(i), split_cal, AR_P, ES_A, ES_B);
    b = run_model(cut_d, keys(i), split_cal, AR_P, ES_A, ES_B);
    check(max(abs(a.y_pred(1:k-split_cal) - b.y_pred)) < 1e-9, ..
          keys(i) + ": a model that never sees rows after k predicts identically up to k");
end

// LR scaling comes from training rows only: perturbing TEST features leaves mu/sigma alone.
mA = run_model(real_data, "LR", split_cal, AR_P, ES_A, ES_B).model;
mB = run_model(pert, "LR", split_cal, AR_P, ES_A, ES_B).model;
check(max(abs(mA.mu - mB.mu)) < 1e-9 & max(abs(mA.sigma - mB.sigma)) < 1e-9 & max(abs(mA.beta - mB.beta)) < 1e-9, ..
      "LR: scaling parameters and coefficients are unaffected by test-period prices");

// ---------------------------------------------------------------------------
// Test 13: compute_metrics and directional accuracy (known values)
// ---------------------------------------------------------------------------
mm = compute_metrics([11; 9; 11; 9], [12; 8; 9; 11], [10; 10; 10; 10]);
check(abs(mm.dir_acc - 50) < 1e-9, "dir_acc: 2 of 4 directions right = 50%");
check(abs(mm.rmse - sqrt(mean([1 1 4 4]))) < 1e-12 & abs(mm.mae - 1.5) < 1e-12, "metrics: RMSE/MAE match hand values");
mm0 = compute_metrics([10; 11; 12], [10; 11; 12], [9; 10; 11]);
check(mm0.rmse == 0 & abs(mm0.dir_acc - 100) < 1e-9 & abs(mm0.r2 - 1) < 1e-12, "metrics: perfect forecast -> RMSE 0, R^2 1, direction 100%");
mz = compute_metrics([0; 5; 10], [1; 5; 9], [1; 0; 5]);
check(~isnan(mz.mape) & ~isinf(mz.mape), "zero-price protection: a zero actual price is excluded from MAPE (no Inf)");
mn = compute_metrics([10; 12; 11], [9; 10; 12], [9; 10; 12]);
check(isnan(mn.dir_acc), "dir_acc: a forecast that never moves from the previous close has no direction score");

// ---------------------------------------------------------------------------
// Test 14: zero/negative prices and constant series
// ---------------------------------------------------------------------------
zero_lines = make_valid_csv_lines(40);
zero_lines(7) = "2024-01-07,0,0,0,0,100";
write_csv(TMP + "zero_price.csv", zero_lines);
dz = load_dataset(TMP + "zero_price.csv");
check(dz.n == 39 & min(dz.close) > 0 & dz.quality.invalid_ohlc == 1, "zero-price protection: a zero-price row is dropped on load and counted");

caught = %f;
try
    run_backtest([100; 0; 100], [100; 100; 100], 0.5, -0.5, 1000, 0, 0);
catch
    caught = %t;
end
check(caught, "zero-price protection: run_backtest rejects a zero price");

const_d = make_data_from_close(100 * ones(120, 1));
for i = 1:4
    rc = run_model(const_d, keys(i), 96, AR_P, ES_A, ES_B);
    check((~isnan(rc.metrics.rmse) & ~isinf(rc.metrics.rmse)) & rc.metrics.rmse < 1e-9 & ~or(isnan(rc.y_pred)), ..
          keys(i) + ": constant series runs without NaN/Inf and is predicted exactly");
end

// ---------------------------------------------------------------------------
// Test 15: naive baseline
// ---------------------------------------------------------------------------
rn = runs(1);
check(max(abs(rn.y_pred - real_data.close(split_cal:nR-1))) < 1e-12, "naive: forecast for day t is the close of day t-1");
chg = real_data.close(split_cal+1:nR) - real_data.close(split_cal:nR-1);
check(abs(rn.metrics.rmse - sqrt(mean(chg.^2))) < 1e-9, "naive: RMSE equals the RMS of one-day price changes on the same window");
check(abs(rn.next_price - real_data.close(nR)) < 1e-12, "naive: next-day forecast is the last close");
lin = make_data_from_close((100:2:218)');          // +2 per day
rl = run_model(lin, "NAIVE", 48, AR_P, ES_A, ES_B);
check(abs(rl.metrics.rmse - 2) < 1e-9, "naive: on a +2/day series the RMSE is exactly 2");
rlr = run_model(lin, "LR", 48, AR_P, ES_A, ES_B);
check(rlr.metrics.rmse < rl.metrics.rmse, "baseline check: LR beats naive on a trending series (as it should)");

// ---------------------------------------------------------------------------
// Test 16: model comparison and ranking come from the actual numbers
// ---------------------------------------------------------------------------
cmp = compare_models(real_data, 0.8, AR_P, ES_A, ES_B, 5);
check(size(cmp.M, 1) == 4 & size(cmp.M, 2) == 8 & size(cmp.results) == 4, "comparison: 4 models x 8 metrics");
check(and(~isnan(cmp.M(:, [1 2 3 4 6 7]))), "comparison: RMSE/MAE/MAPE/R^2/WF metrics are filled for every model");
for i = 1:4
    check(abs(cmp.M(i, 1) - runs(i).metrics.rmse) < 1e-12, cmp.labels(i) + ": comparison RMSE equals the stand-alone run_model RMSE (same window)");
end
check(isnan(cmp.M(1, 5)) & and(~isnan(cmp.M(2:4, 5))), "comparison: naive has no direction accuracy, the three models do");
check(gsort(cmp.rank.order, "g", "i")' == 1:4, "ranking: order is a permutation of the four models");
check(cmp.rank.best_idx >= 2 & cmp.rank.best_idx <= 4, "ranking: the best StockVision model is one of LR/AR/ES");

Mfake = [10 8 5 50 %nan 12 9 %nan; 4 3 2 90 60 5 4 55; 6 5 3 80 55 7 6 52; 7 6 4 70 52 8 7 50];
rk = rank_models(Mfake, ["Naive"; "LR"; "AR"; "ES"]);
check(rk.order(1) == 2 & rk.best_idx == 2, "ranking: a model that is best on every metric ranks first");
check(rk.skill_rmse(2) > 0 & rk.naive_rank_pos == 4, "ranking: model beating naive has positive skill; naive ranks last");
Mfake2 = [1 1 1 99 %nan 1 1 %nan; 2 2 2 90 50 2 2 50; 3 3 3 80 52 3 3 51; 4 4 4 70 54 4 4 52];
rk2 = rank_models(Mfake2, ["Naive"; "LR"; "AR"; "ES"]);
check(rk2.order(1) == 1 & rk2.skill_rmse(2) < 0 & rk2.best_idx == 2, ..
      "ranking: when naive wins it ranks first and every model gets NEGATIVE skill (reported honestly)");
txt = format_ranking(cmp);
check(or(strindex(strcat(txt, " "), "Best StockVision model") <> []), "ranking text names the best model");

// ---------------------------------------------------------------------------
// Test 17: walk-forward (multi-fold, chronological, no leakage)
// ---------------------------------------------------------------------------
wf = cmp.wf;
check(wf.n_used == 5 & wf.n_req == 5 & wf.reason == "", "walk-forward: 5 folds used when the data supports them");
check(and(wf.train_end(2:$) == wf.test_end(1:$-1)) & wf.test_end($) == nR & wf.train_end(1) == wf.min_train, ..
      "walk-forward: folds are contiguous, non-overlapping and reach the last row");
check(and(wf.train_end < wf.test_end), "walk-forward: every fold trains strictly before it tests");
check(abs(wf.mean_rmse(2) - mean(wf.fold_rmse(:, 2))) < 1e-12, "walk-forward: mean RMSE is the mean of the fold RMSEs");

// Independent fold-1 check for the naive model (pure arithmetic on prices).
te1 = wf.train_end(1)+1:wf.test_end(1);
nv = real_data.close(te1) - real_data.close(te1 - 1);
check(abs(wf.fold_rmse(1, 1) - sqrt(mean(nv.^2))) < 1e-9, "walk-forward: fold-1 naive RMSE matches an independent recomputation");

// Future changes after the last-but-one fold cannot alter earlier folds.
kk = wf.test_end(4);
pert2 = real_data; pert2.close(kk+1:$) = pert2.close(kk+1:$) * 2; pert2.open(kk+1:$) = pert2.open(kk+1:$) * 2;
pert2.high(kk+1:$) = pert2.high(kk+1:$) * 2; pert2.low(kk+1:$) = pert2.low(kk+1:$) * 2;
wfp = walk_forward_all(pert2, 5, AR_P, ES_A, ES_B);
check(max(abs(wfp.fold_rmse(1:4, :) - wf.fold_rmse(1:4, :))) < 1e-9, "walk-forward: folds 1-4 are unchanged by changes to later (fold 5) data");

// Too little data: fold count is reduced with a stated reason; tiny data errors.
small = slice_data(real_data, 75);
wfs = walk_forward_all(small, 5, AR_P, ES_A, ES_B);
check(wfs.n_used < 5 & wfs.n_used >= 1 & wfs.reason <> "", "walk-forward: too little data reduces the fold count and says why");
caught = %f;
try
    walk_forward_all(slice_data(real_data, 45), 5, AR_P, ES_A, ES_B);
catch
    caught = %t;
end
check(caught, "walk-forward: a dataset too small for even one fold is rejected, never faked");

// ---------------------------------------------------------------------------
// Test 18: backtest rigor -- lag, costs, slippage, buy & hold, trades
// ---------------------------------------------------------------------------
// Signal on day 2 (forecast +5% vs day 1) trades at close of day 2 (price 100);
// only the day 3 and day 4 returns (+10% each) are earned.
ya = [100; 100; 110; 121]; yp = [100; 105; 110; 121];
b0 = run_backtest(ya, yp, 0.5, -0.5, 100000, 0, 0);
check(abs(b0.strategy_final - 100000 * 1.21) < 1e-6, "execution lag: a day-2 BUY earns only the day-3/day-4 returns");
check(abs(b0.position(2) - 1) < 1e-12 & b0.n_trades == 1, "execution lag: position is held from the close of day 2");
b1 = run_backtest(ya, yp, 0.5, -0.5, 100000, 1, 0.5);
check(abs(b1.strategy_final - 100000 * (1 - 0.015) * 1.21) < 1e-6, "costs: 1% cost + 0.5% slippage deduct exactly 1.5% on the BUY");
check(b1.strategy_final < b0.strategy_final, "costs: costs lower the ending capital");

// Round trip with a known net-of-cost trade return.
ya2 = [100; 100; 110; 121; 121]; yp2 = [100; 105; 110; 121; 90];
b2 = run_backtest(ya2, yp2, 0.5, -0.5, 1000, 1, 0);
check(b2.n_completed_trades == 1 & b2.n_trades == 2, "trades: one BUY + one SELL = one completed round trip");
check(abs(b2.trade_gross(1) - 0.21) < 1e-12 & abs(b2.trade_net(1) - (1.21 * 0.99^2 - 1)) < 1e-12, "trades: net return deducts entry and exit cost");
check(b2.n_wins == 1 & b2.n_losses == 0 & abs(b2.win_rate_pct - 100) < 1e-12, "trades: winning/losing counts and win rate");

// Buy & hold uses the same evaluation window.
y_t = runs(2).y_true; y_p = runs(2).y_pred;
bb = run_backtest(y_t, y_p, 0.5, -0.5, 100000, 0, 0);
check(size(bb.buyhold_value, 1) == size(y_t, 1) & size(bb.strategy_value, 1) == size(y_t, 1), "buy & hold: curve covers exactly the strategy evaluation window");
check(abs(bb.buyhold_final - 100000 * y_t($) / y_t(1)) < 1e-6, "buy & hold: ending capital = start * last/first test close");
bc = run_backtest(y_t, y_p, 0.5, -0.5, 100000, 0.2, 0.1);
check(abs(bc.buyhold_final - 100000 * 0.997 * y_t($) / y_t(1)) < 1e-6, "buy & hold: pays one entry cost under the same cost assumptions");

// Drawdown and Sharpe against independent calculations.
sv = bb.strategy_value; run_pk = sv(1); mdd = 0;
for i = 1:size(sv, 1); if sv(i) > run_pk then run_pk = sv(i); end; mdd = max(mdd, (run_pk - sv(i)) / run_pk * 100); end
check(abs(bb.max_drawdown_pct - mdd) < 1e-9, "drawdown: matches an independent peak-to-trough calculation");
dr_ = sv(2:$) ./ sv(1:$-1) - 1;
if stdev(dr_) > 1e-12 then
    check(abs(bb.sharpe_ratio - mean(dr_) / stdev(dr_) * sqrt(252)) < 1e-9, "Sharpe: matches mean/std*sqrt(252) of daily returns");
else
    check(isnan(bb.sharpe_ratio), "Sharpe: undefined when returns have zero variance");
end
check(bb.n_days == size(y_t, 1) - 1 & ~isnan(bb.annualized_return_pct), "annualized return is reported when >= 30 days exist");
bshort = run_backtest(y_t(1:10), y_p(1:10), 0.5, -0.5, 1000, 0, 0);
check(isnan(bshort.annualized_return_pct), "annualized return is withheld for windows shorter than 30 days");

// ---------------------------------------------------------------------------
// Test 19: report/CSV export (never overwrites; content comes from results)
// ---------------------------------------------------------------------------
r_sel = cmp.results(2);
sig = generate_signal(real_data.close($), r_sel.next_price, 0.5, -0.5);
sig.current_price = real_data.close($); sig.buy_thr = 0.5; sig.sell_thr = -0.5;
bt_e = run_backtest(r_sel.y_true, r_sel.y_pred, 0.5, -0.5, 100000, 0.1, 0.05);
cfg = struct("split_ratio", 0.8, "ar_lookback", AR_P, "es_alpha", ES_A, "es_beta", ES_B, "n_folds", 5, ..
             "buy", 0.5, "sell", -0.5, "cost", 0.1, "slip", 0.05, "capital", 100000);
asm = struct("capital", 100000, "cost", 0.1, "slip", 0.05, "buy", 0.5, "sell", -0.5, "split_ratio", 0.8, ..
             "n", nR, "train_first", real_data.dates(1), "train_last", dq.train_last, ..
             "test_first", dq.test_first, "test_last", real_data.dates($), "train_rows", dq.train_rows, "test_rows", dq.test_rows);
rep = struct("dataset_label", "Tech test", "data", real_data, "dq", dq, "cfg", cfg, "analysis", r_sel, ..
             "naive", cmp.results(1), "signal", sig, "validated", %t, "cmp", cmp, "bt", bt_e, "assump", asm);
out_base = TMP + "export_test";
export_report_txt(out_base + ".txt", rep);
rep_txt = strcat(mgetl(out_base + ".txt"), "|");
check(isfile(out_base + ".txt") & strindex(rep_txt, "WALK-FORWARD VALIDATION") <> [] & strindex(rep_txt, "BACKTEST ASSUMPTIONS") <> [] & ..
      strindex(rep_txt, "MODEL RANKING") <> [] & strindex(rep_txt, "Buy & Hold") <> [] & strindex(rep_txt, "Generated:") <> [], ..
      "export: TXT report contains comparison, ranking, walk-forward, assumptions, buy & hold and a timestamp");
written = export_companion_csvs(out_base, rep);
check(size(written, 1) == 4 & and(isfile(written)), "export: predictions, comparison, walk-forward and backtest CSVs are written");
written2 = export_companion_csvs(out_base, rep);
check(and(written2 <> written) & and(isfile(written)), "export: a second export gets new file names and never overwrites the first");
export_results_csv(out_base + "_single.csv", rep);
csvl = mgetl(out_base + "_single.csv");
check(csvl(1) == "Metric,Value" & or(part(csvl, 1:5) == "RMSE,"), "export: single-file CSV keeps the Metric,Value layout");
check(or(part(csvl, 1:19) == "Backtest_Slippage_p") & or(part(csvl, 1:22) == "Backtest_Transaction_C"), "export: CSV records transaction cost and slippage");

// build_report_struct (shared by the sample generator and the exports)
rep2 = build_report_struct("Tech test", real_data, cfg, "AR", %t);
check(rep2.analysis.label == "AR" & typeof(rep2.bt) == "st" & rep2.cmp.wf.n_used == 5 & rep2.assump.test_rows == nR - split_cal, ..
      "build_report_struct: runs comparison, walk-forward and backtest for the chosen model");
rep3 = build_report_struct("Tech test", real_data, cfg, "ES", %f);
check(~(typeof(rep3.bt) == "st"), "build_report_struct: no backtest when not requested");

// Model-info text is technically precise.
info_ar = strcat(model_info_text("AR", 10, 0.3, 0.1), " ");
check(strindex(info_ar, "NOT an LSTM") <> [], "model info: AR text states it is not an LSTM");

mprintf("\n========================================\n");
mprintf("ALL MODEL ENGINE TESTS PASSED\n");
mprintf("========================================\n");

exit;
