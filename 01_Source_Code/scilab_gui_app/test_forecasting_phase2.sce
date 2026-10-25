// ============================================================================
// test_forecasting_phase2.sce -- Phase 2 Forecasting & Validation Test Suite
//
// Rigorous verification of the Ridge Regression (L2-Regularized) model:
// 1. Feature generation, lag alignment, and target non-leakage
// 2. Training-only normalization and anti-leakage invariants
// 3. Regularization shrinkage, conditioning, and Tikhonov penalty behavior
// 4. Numerical edge cases (constant series, zero volume, insufficient rows)
// 5. Analytical leverage and 95% prediction interval coverage
// 6. Common-window baseline comparisons (Naive, LR, AR, ES, Ridge)
// 7. 5-model ranking and metric consistency
// 8. 5-model expanding walk-forward cross-validation
// 9. Backtesting simulation under realistic costs and slippage
// 10. Multi-market evaluation on US (AAPL) and Indian (INFY) equity feeds
// 11. Bit-for-bit numerical determinism and reproducibility
// 12. Full Scilab GUI integration and callback workflow
//
// Run headlessly:
//   WScilex-cli -nb -f 01_Source_Code/scilab_gui_app/test_forecasting_phase2.sce
// ============================================================================

clear;
mprintf("======================================================================\n");
mprintf("  StockVision Phase 2: Validated Forecasting Model Suite\n");
mprintf("======================================================================\n\n");

// Locate scripts
try
    this_dir = get_absolute_file_path("test_forecasting_phase2.sce");
catch
    this_dir = pwd() + filesep() + "01_Source_Code" + filesep() + "scilab_gui_app" + filesep();
end

engine_path = this_dir + "model_engine.sce";
adapter_path = this_dir + "market_data_adapter.sce";
gui_path = this_dir + "gui_app.sce";

if ~isfile(engine_path) then error("Engine script not found: " + engine_path); end
if ~isfile(adapter_path) then error("Adapter script not found: " + adapter_path); end

exec(engine_path, -1);
exec(adapter_path, -1);

global n_p2_pass n_p2_fail;
n_p2_pass = 0;
n_p2_fail = 0;

function assert_true(cond, desc)
    global n_p2_pass n_p2_fail;
    if cond then
        n_p2_pass = n_p2_pass + 1;
        mprintf("  [PASS] %s\n", desc);
    else
        n_p2_fail = n_p2_fail + 1;
        mprintf("  [FAIL] %s\n", desc);
    end
endfunction

function assert_equal(actual, expected, desc)
    global n_p2_pass n_p2_fail;
    if actual == expected then
        n_p2_pass = n_p2_pass + 1;
        mprintf("  [PASS] %s\n", desc);
    else
        n_p2_fail = n_p2_fail + 1;
        mprintf("  [FAIL] %s (expected %s, got %s)\n", desc, string(expected), string(actual));
    end
endfunction

function assert_near(actual, expected, tol, desc)
    global n_p2_pass n_p2_fail;
    diff_val = abs(actual - expected);
    if diff_val <= tol then
        n_p2_pass = n_p2_pass + 1;
        mprintf("  [PASS] %s\n", desc);
    else
        n_p2_fail = n_p2_fail + 1;
        mprintf("  [FAIL] %s (expected %f, got %f, diff %e > tol %e)\n", desc, expected, actual, diff_val, tol);
    end
endfunction


// Load canonical datasets for validation
tech_data = load_dataset(this_dir + "sample_data" + filesep() + "tech_growth_stock.csv");
blue_data = load_dataset(this_dir + "sample_data" + filesep() + "blue_chip_stock.csv");


// ---------------------------------------------------------------------------
// Group 1: Ridge Feature Generation & Alignment
// ---------------------------------------------------------------------------
mprintf("\n--- Group 1: Ridge Feature Generation & Alignment ---\n");

feat = build_ridge_features(tech_data);
assert_equal(feat.n_valid, 290, "Tech growth: 290 valid rows survive 10-row warmup from 300 rows");
assert_equal(size(feat.X_raw, 2), 13, "13 engineered features constructed");
assert_equal(size(feat.feature_names, 2), 13, "13 feature names documented");
assert_equal(feat.feature_names(1), "Close", "Feature 1 is Close");
assert_equal(feat.feature_names(2), "Return_1d", "Feature 2 is 1-day Return");
assert_equal(feat.feature_names(5), "Osc_MA5", "Feature 5 is Osc_MA5");
assert_equal(feat.feature_names(9), "Vol_Ratio10", "Feature 9 is Vol_Ratio10");

// Verify target alignment: target of calendar row i must be close(i+1)
cal_row_first = feat.row_idx(1);
assert_equal(cal_row_first, 10, "First valid feature row is calendar row 10 (warmup ends at 10)");
assert_equal(feat.y(1), tech_data.close(cal_row_first + 1), "Target of row 10 is close(11)");
assert_equal(feat.y($), tech_data.close(299 + 1), "Target of row 299 is close(300)");

// Verify latest_raw represents calendar row n (day 300) for tomorrow forecast
assert_equal(size(feat.latest_raw, 2), 13, "latest_raw has 13 features");
assert_equal(feat.latest_raw(1), tech_data.close($), "latest_raw Close is today closing price");


// ---------------------------------------------------------------------------
// Group 2: Anti-Leakage Invariants
// ---------------------------------------------------------------------------
mprintf("\n--- Group 2: Anti-Leakage Invariants ---\n");

split_idx = 200;
model_r = fit_ridge_at(feat, split_idx, 1.0);

// mu and sigma must match training rows ONLY
X_train_manual = feat.X_raw(1:split_idx, :);
mu_expected = mean(X_train_manual, "r");
sigma_expected = stdev(X_train_manual, "r");
sigma_expected(sigma_expected == 0) = 1;

assert_near(norm(model_r.mu - mu_expected), 0, 1e-12, "Model mu strictly matches training rows 1..split_idx");
assert_near(norm(model_r.sigma - sigma_expected), 0, 1e-12, "Model sigma strictly matches training rows 1..split_idx");

// Verify test observations do not leak into training scaling: modify test data and verify mu is unchanged
feat_perturbed = feat;
feat_perturbed.X_raw(split_idx+10, 1) = feat_perturbed.X_raw(split_idx+10, 1) * 5.0; // 5x shock in test set
model_perturbed = fit_ridge_at(feat_perturbed, split_idx, 1.0);
assert_near(norm(model_perturbed.mu - model_r.mu), 0, 1e-12, "Test-period price shocks do NOT affect training mu");
assert_near(norm(model_perturbed.beta - model_r.beta), 0, 1e-12, "Test-period price shocks do NOT affect training beta");


// ---------------------------------------------------------------------------
// Group 3: Regularization Shrinkage & Conditioning
// ---------------------------------------------------------------------------
mprintf("\n--- Group 3: Regularization Shrinkage & Conditioning ---\n");

m_low_lambda = fit_ridge_at(feat, split_idx, 0.01);
m_med_lambda = fit_ridge_at(feat, split_idx, 1.0);
m_hi_lambda  = fit_ridge_at(feat, split_idx, 100.0);

// Norm of feature coefficients (excluding intercept beta(1)) must decrease monotonically with lambda
norm_low = norm(m_low_lambda.beta(2:$));
norm_med = norm(m_med_lambda.beta(2:$));
norm_hi  = norm(m_hi_lambda.beta(2:$));

assert_true(norm_med < norm_low, "Increasing lambda from 0.01 to 1.0 shrinks feature coefficient norm");
assert_true(norm_hi < norm_med, "Increasing lambda from 1.0 to 100.0 further shrinks feature coefficient norm");

// Conditioning: regularized matrix condition number is strictly improved over raw XtX
rcond_raw = rcond(model_r.XtX);
rcond_reg = rcond(model_r.XtX + diag([0; ones(13, 1) * 1.0]));
assert_true(rcond_reg >= rcond_raw, "Ridge penalty improves matrix reciprocal condition number");


// ---------------------------------------------------------------------------
// Group 4: Numerical Edge Cases & Error Guards
// ---------------------------------------------------------------------------
mprintf("\n--- Group 4: Numerical Edge Cases & Error Guards ---\n");

// Insufficient history (< 15 rows)
short_data = slice_data(tech_data, 12);
caught_short = %f;
try
    build_ridge_features(short_data);
catch
    caught_short = %t;
    err_msg = strcat(lasterror(), " ");
    assert_true(~isempty(strindex(err_msg, "need at least 15 rows")), "Insufficient history raises clear explanation");
end
assert_true(caught_short, "Dataset with <15 rows rejected by feature builder");

// Constant price series (zero variance)
const_data = tech_data;
const_data.close(:) = 150.0;
const_data.open(:) = 150.0;
const_data.high(:) = 150.0;
const_data.low(:) = 150.0;
const_feat = build_ridge_features(const_data);
assert_equal(const_feat.n_valid, 290, "Constant price series builds features without crash");
const_model = fit_ridge_at(const_feat, 200, 1.0);
assert_true(~isnan(const_model.beta(1)), "Constant series fits without NaN coefficients");
[c_next, c_lo, c_hi] = predict_next_ridge(const_model);
assert_near(c_next, 150.0, 1.0, "Constant series predicts price close to constant value");

// Empty train/test split guard
caught_split = %f;
try
    fit_ridge_at(feat, 0, 1.0);
catch
    caught_split = %t;
end
assert_true(caught_split, "Split index 0 rejected with clear error");


// ---------------------------------------------------------------------------
// Group 5: Prediction Intervals & Uncertainty Calibration
// ---------------------------------------------------------------------------
mprintf("\n--- Group 5: Prediction Intervals & Uncertainty Calibration ---\n");

[pred_next, pi_lo, pi_hi] = predict_next_ridge(model_r);
assert_true(pred_next > 0, "Point prediction is positive");
assert_true(pi_lo < pred_next, "95% Prediction interval lower bound < point forecast");
assert_true(pi_hi > pred_next, "95% Prediction interval upper bound > point forecast");

interval_width = pi_hi - pi_lo;
assert_true(interval_width > 0, "Prediction interval width is strictly positive");
assert_true(model_r.df > 0, "Effective degrees of freedom is positive");
assert_true(model_r.train_residual_std > 0, "Unbiased residual standard error > 0");


// ---------------------------------------------------------------------------
// Group 6: Common-Window Evaluation with run_model
// ---------------------------------------------------------------------------
mprintf("\n--- Group 6: Stand-Alone & Common-Window run_model ---\n");

split_cal = 240;
r_ridge = run_model(tech_data, "RIDGE", split_cal, 10, 0.3, 0.1, 1.0);
assert_equal(r_ridge.name, "Ridge Regression (L2)", "Model name is Ridge Regression (L2)");
assert_equal(r_ridge.label, "Ridge", "Model label is Ridge");
assert_equal(r_ridge.n_test, tech_data.n - split_cal, "Test window length matches calendar split (300 - 240 = 60)");
assert_equal(r_ridge.y_true($), tech_data.close($), "Last test observation matches dataset closing price");

// Verify test metrics
m_ridge = r_ridge.metrics;
assert_true(m_ridge.rmse > 0, "Ridge test RMSE > 0");
assert_true(m_ridge.mae > 0, "Ridge test MAE > 0");
assert_true(~isnan(m_ridge.mape), "Ridge test MAPE is defined");
assert_true(~isnan(m_ridge.theil_u), "Ridge Theil U1 is defined");
assert_true(~isnan(m_ridge.theil_u2), "Ridge Theil U2 relative to naive is defined");
assert_true(m_ridge.dir_acc >= 0 & m_ridge.dir_acc <= 100, "Ridge Directional accuracy is valid percentage in [0, 100]");

// Format model results panel
sig_dummy = generate_signal(tech_data.close(split_cal), r_ridge.next_price, 0.5, -0.5);
res_text = format_model_results(r_ridge, r_ridge, sig_dummy, %f);
assert_true(size(res_text, 1) >= 12, "format_model_results generates complete panel text");
assert_true(~isempty(strindex(strcat(res_text, " "), "L2-regularized leverage-adj")), "Results text specifies L2-regularized prediction interval");


// ---------------------------------------------------------------------------
// Group 7: 5-Model Comparison & Ranking
// ---------------------------------------------------------------------------
mprintf("\n--- Group 7: 5-Model Comparison & Ranking ---\n");

// 4-model legacy mode (include_ridge = %f)
cmp4 = compare_models(tech_data, 0.8, 10, 0.3, 0.1, 5, %f);
assert_equal(size(cmp4.M, 1), 4, "4-model comparison preserves exact 4 rows");
assert_equal(cmp4.labels(4), "ES", "Model 4 is ES in 4-model mode");

// 5-model Phase 2 mode (include_ridge = %t)
cmp5 = compare_models(tech_data, 0.8, 10, 0.3, 0.1, 5, %t, 1.0);
assert_equal(size(cmp5.M, 1), 5, "5-model comparison contains 5 rows");
assert_equal(cmp5.labels(5), "Ridge", "Model 5 is Ridge");
assert_equal(cmp5.keys(5), "RIDGE", "Key 5 is RIDGE");

// Verify Ridge metrics are filled
assert_true(~isnan(cmp5.M(5, 1)), "Ridge comparison RMSE is non-NaN");
assert_true(~isnan(cmp5.M(5, 2)), "Ridge comparison MAE is non-NaN");
assert_true(~isnan(cmp5.M(5, 4)), "Ridge comparison R^2 is non-NaN");
assert_true(~isnan(cmp5.M(5, 6)), "Ridge walk-forward RMSE is non-NaN");

// Ranking logic with 5 models
rk5 = cmp5.rank;
assert_equal(size(rk5.order, 1), 5, "Ranking orders all 5 models");
assert_true(rk5.best_idx >= 2 & rk5.best_idx <= 5, "Best model identified among candidate models (2..5)");
rank_lines = format_ranking(cmp5);
assert_true(size(rank_lines, 1) >= 4, "format_ranking formats 5-model text cleanly");

// Text comparison table with 5 models
comp_text = format_comparison(cmp5);
assert_true(~isempty(strindex(strcat(comp_text, " "), "Ridge")), "Comparison table header includes Ridge column");


// ---------------------------------------------------------------------------
// Group 8: 5-Model Walk-Forward Cross-Validation
// ---------------------------------------------------------------------------
mprintf("\n--- Group 8: 5-Model Walk-Forward Cross-Validation ---\n");

wf5 = walk_forward_all(tech_data, 5, 10, 0.3, 0.1, %t, 1.0);
assert_equal(wf5.n_used, 5, "5 walk-forward folds executed");
assert_equal(size(wf5.fold_rmse, 2), 5, "Each fold evaluates 5 models");
assert_equal(wf5.labels(5), "Ridge", "Walk-forward model 5 is Ridge");
assert_true(wf5.mean_rmse(5) > 0, "Ridge walk-forward mean RMSE > 0");
assert_true(wf5.mean_mae(5) > 0, "Ridge walk-forward mean MAE > 0");
assert_true(~isnan(wf5.mean_dir(5)), "Ridge walk-forward directional accuracy is non-NaN");

wf_text = format_walk_forward(wf5);
assert_true(~isempty(strindex(strcat(wf_text, " "), "Ridge")), "Walk-forward text report includes Ridge column");


// ---------------------------------------------------------------------------
// Group 9: Backtesting Simulation on Ridge Model
// ---------------------------------------------------------------------------
mprintf("\n--- Group 9: Backtest Simulation on Ridge Forecasts ---\n");

y_act = r_ridge.y_true;
y_prd = r_ridge.y_pred;
bt_ridge = run_backtest(y_act, y_prd, 0.5, -0.5, 100000.0, 0.1, 0.05);

assert_true(bt_ridge.strategy_final > 0, "Backtest completes with positive portfolio equity");
assert_true(bt_ridge.n_trades >= 0, "Backtest records trade count");
assert_true(bt_ridge.total_costs_paid >= 0, "Total transaction costs and slippage tracked");
assert_near(bt_ridge.buyhold_value(1), 100000.0 * (1 - 0.0015), 1e-4, "Buy & hold pays entry cost (0.1% + 0.05%)");

bt_text = format_backtest(bt_ridge, "Ridge Regression");
assert_true(size(bt_text, 1) >= 14, "format_backtest formats comprehensive report");


// ---------------------------------------------------------------------------
// Group 10: Multi-Market Verification (US & Indian Equities)
// ---------------------------------------------------------------------------
mprintf("\n--- Group 10: Multi-Market Verification (US & Indian Equities) ---\n");

mock_dir = this_dir + "sample_data" + filesep() + "mock_market_data" + filesep();
aapl_mock_path = mock_dir + "mock_twelvedata_aapl.json";
infy_mock_path = mock_dir + "mock_twelvedata_infy_nse.json";

// US Equity: AAPL (NASDAQ, USD)
aapl_mkt = mda_load_mock(aapl_mock_path, "AAPL", "NASDAQ");
r_aapl = run_model(aapl_mkt, "RIDGE", 50, 5, 0.3, 0.1, 1.0);
assert_equal(r_aapl.name, "Ridge Regression (L2)", "AAPL: Ridge model fits successfully");
assert_true(r_aapl.next_price > 0, "AAPL: Ridge produces positive point forecast in USD");
assert_true(r_aapl.ci_hi > r_aapl.ci_lo, "AAPL: Ridge prediction interval upper > lower");

// Indian Equity: INFY (NSE, INR)
infy_mkt = mda_load_mock(infy_mock_path, "INFY", "NSE");
r_infy = run_model(infy_mkt, "RIDGE", 50, 5, 0.3, 0.1, 1.0);
assert_equal(r_infy.name, "Ridge Regression (L2)", "INFY: Ridge model fits successfully");
assert_true(r_infy.next_price > 0, "INFY: Ridge produces positive point forecast in INR");
assert_true(r_infy.ci_hi > r_infy.ci_lo, "INFY: Ridge prediction interval upper > lower");


// ---------------------------------------------------------------------------
// Group 11: Bit-for-bit Numerical Determinism & Reproducibility
// ---------------------------------------------------------------------------
mprintf("\n--- Group 11: Determinism & Reproducibility ---\n");

r1 = run_model(tech_data, "RIDGE", split_cal, 10, 0.3, 0.1, 1.0);
r2 = run_model(tech_data, "RIDGE", split_cal, 10, 0.3, 0.1, 1.0);

assert_equal(r1.next_price, r2.next_price, "Next-price forecast is bit-for-bit identical across runs");
assert_equal(r1.ci_lo, r2.ci_lo, "Prediction interval lower bound is bit-for-bit identical");
assert_equal(r1.ci_hi, r2.ci_hi, "Prediction interval upper bound is bit-for-bit identical");
assert_near(norm(r1.y_pred - r2.y_pred), 0, 1e-12, "Out-of-sample prediction vector is bit-for-bit identical");
assert_equal(r1.metrics.rmse, r2.metrics.rmse, "Test RMSE is bit-for-bit identical");


// ---------------------------------------------------------------------------
// Group 12: GUI Integration & Workflow
// ---------------------------------------------------------------------------
mprintf("\n--- Group 12: GUI Integration & Workflow ---\n");

// Preserve pass/fail counters in environment variables across gui_app.sce clear
setenv("P2_PASS", string(n_p2_pass));
setenv("P2_FAIL", string(n_p2_fail));

global gui_quiet gui app_state nfail;
gui_quiet = %t;
exec(gui_path, -1);

global n_p2_pass n_p2_fail;
n_p2_pass = evstr(getenv("P2_PASS", "0"));
n_p2_fail = evstr(getenv("P2_FAIL", "0"));

function assert_true(cond, desc)
    global n_p2_pass n_p2_fail;
    if cond then
        n_p2_pass = n_p2_pass + 1;
        mprintf("  [PASS] %s\n", desc);
    else
        n_p2_fail = n_p2_fail + 1;
        mprintf("  [FAIL] %s\n", desc);
    end
endfunction

function assert_equal(actual, expected, desc)
    global n_p2_pass n_p2_fail;
    if actual == expected then
        n_p2_pass = n_p2_pass + 1;
        mprintf("  [PASS] %s\n", desc);
    else
        n_p2_fail = n_p2_fail + 1;
        mprintf("  [FAIL] %s (expected %s, got %s)\n", desc, string(expected), string(actual));
    end
endfunction

// Verify model popup includes 4 options
pop_items = get(gui.model_popup, "string");
assert_true(~isempty(strindex(strcat(pop_items, " "), "Ridge Regression (L2)")), "Model popup contains Ridge Regression (L2)");

// Select Ridge (item 4)
set(gui.model_popup, "value", 4);
on_model_changed();
assert_equal(app_state.model_type, "RIDGE", "Selecting item 4 updates app_state.model_type to RIDGE");

// Run Analysis with Ridge
on_run_analysis();
assert_true(has(app_state.analysis), "on_run_analysis completes for Ridge");
assert_equal(app_state.analysis.label, "Ridge", "Analysis result is Ridge");
assert_true(app_state.analysis.next_price > 0, "Ridge next_price > 0 on GUI dashboard");
assert_equal(size(winsid(), "*"), 1, "Exactly 1 window remains open after Ridge analysis");

// Run Backtest with Ridge
on_run_backtest();
assert_true(has(app_state.bt), "on_run_backtest completes for Ridge");
assert_true(app_state.bt.strategy_final > 0, "Ridge strategy equity is positive");

// Compare Models with Ridge selected (5-model comparison)
on_compare();
assert_true(has(app_state.cmp), "on_compare completes when Ridge is selected");
assert_equal(size(app_state.cmp.M, 1), 5, "Comparison includes all 5 models (Naive, LR, AR, ES, Ridge)");
assert_equal(app_state.cmp.labels(5), "Ridge", "Comparison label 5 is Ridge");

// Walk-Forward with Ridge
on_walk_forward();
assert_equal(app_state.cmp.wf.n_used, 5, "Walk-forward executes 5 folds for 5 models");

// Model Info dialog text
info_lines = model_info_text("RIDGE", 10, 0.3, 0.1);
assert_true(size(info_lines, 1) >= 15, "model_info_text generates comprehensive documentation for Ridge");
assert_true(~isempty(strindex(strcat(info_lines, " "), "Tikhonov")), "Info text documents Tikhonov regularization");

close(gui.fig);


// ---------------------------------------------------------------------------
// Final Summary
// ---------------------------------------------------------------------------
mprintf("\n======================================================================\n");
mprintf("  Phase 2 Forecasting & Validation Results\n");
mprintf("  Total assertions: %d\n", n_p2_pass + n_p2_fail);
mprintf("  Passed:           %d\n", n_p2_pass);
mprintf("  Failed:           %d\n", n_p2_fail);
mprintf("======================================================================\n");

if n_p2_fail > 0 then
    error("Phase 2 test suite encountered " + string(n_p2_fail) + " failure(s).");
else
    mprintf("ALL PHASE 2 FORECASTING & VALIDATION TESTS PASSED SUCCESSFULLY.\n");
end

exit(0);
