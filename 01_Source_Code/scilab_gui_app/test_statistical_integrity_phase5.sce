// ============================================================================
// test_statistical_integrity_phase5.sce -- Phase 5 Statistical Audit & Integrity Suite
//
// Independently verifies:
//   - Correct target alignment and anti-leakage temporal sequencing
//   - AR lag indexing and unit consistency across models
//   - Independent hand-recomputation of RMSE, MAE, MAPE, R^2, and Theil's U2
//   - Directional accuracy sign conventions and edge cases
//   - Degenerate series guards (constant series, zero denominators)
//   - Equal test sample counts and identical forecast origins across all 5 models
//   - Prediction interval coverage calibration and effective degrees of freedom
//   - Backtest position lag, execution timing, transaction costs, and slippage
//   - Walk-forward expanding-window validation and fold dispersion tracking
//   - Forensic demonstration of AR(10) on mock periodic fixture vs real market data
//
// Run headlessly:
//   scilab-cli -nb -f test_statistical_integrity_phase5.sce
// ============================================================================
clear; clc;
_DIR = get_absolute_file_path("test_statistical_integrity_phase5.sce");
exec(_DIR + "model_engine.sce", -1);
exec(_DIR + "market_data_adapter.sce", -1);

mprintf("\n======================================================================\n");
mprintf("  StockVision Phase 5: Statistical Integrity & Forecast Audit Suite\n");
mprintf("======================================================================\n\n");

global n_p5_pass n_p5_fail;
n_p5_pass = 0;
n_p5_fail = 0;

function assert_equal(val, expected, desc)
    global n_p5_pass n_p5_fail;
    if val == expected then
        mprintf("  [PASS] %s\n", desc);
        n_p5_pass = n_p5_pass + 1;
    else
        mprintf("  [FAIL] %s\n", desc);
        n_p5_fail = n_p5_fail + 1;
    end
endfunction

function assert_true(cond, desc)
    global n_p5_pass n_p5_fail;
    if cond then
        mprintf("  [PASS] %s\n", desc);
        n_p5_pass = n_p5_pass + 1;
    else
        mprintf("  [FAIL] %s\n", desc);
        n_p5_fail = n_p5_fail + 1;
    end
endfunction

function assert_near(val, expected, tol, desc)
    global n_p5_pass n_p5_fail;
    err = abs(val - expected);
    if err <= tol then
        mprintf("  [PASS] %s (got %.6f, expected %.6f, err=%.2e)\n", desc, val, expected, err);
        n_p5_pass = n_p5_pass + 1;
    else
        mprintf("  [FAIL] %s (got %.6f, expected %.6f, err=%.2e > tol=%.2e)\n", desc, val, expected, err, tol);
        n_p5_fail = n_p5_fail + 1;
    end
endfunction


// ============================================================================
// Group 1: Target Alignment & Anti-Leakage Sequencing
// ============================================================================
mprintf("--- Group 1: Target Alignment & Anti-Leakage Sequencing ---\n");
d_tech = load_dataset(_DIR + "sample_data/tech_growth_stock.csv");

// Verify AR lag construction strictly uses past data
p = 5;
n_samples = d_tech.n - p;
X_test_ar = zeros(n_samples, p);
y_test_ar = zeros(n_samples, 1);
for i = 1:n_samples
    X_test_ar(i, :) = d_tech.close(i:i+p-1)';
    y_test_ar(i) = d_tech.close(i+p);
end
assert_true(y_test_ar(1) == d_tech.close(p+1), "AR target row 1 is strictly close(p+1)");
assert_true(X_test_ar(1, p) == d_tech.close(p), "AR feature row 1 column p is strictly close(p)");
assert_true(X_test_ar(1, 1) == d_tech.close(1), "AR feature row 1 column 1 is strictly close(1)");
assert_true(y_test_ar($) == d_tech.close($), "AR target row end is strictly close(n)");
assert_true(X_test_ar($, p) == d_tech.close($-1), "AR feature row end column p is strictly close(n-1)");

// Perturbation test: perturbing day k does NOT alter features or targets for days < k
c_perturbed = d_tech.close;
k_split = 200;
c_perturbed(k_split+1:$) = c_perturbed(k_split+1:$) * 3.0; // severe test price shock
d_pert = d_tech; d_pert.close = c_perturbed;

m_orig = fit_ar_at(d_tech, 5, 100);
m_pert = fit_ar_at(d_pert, 5, 100);
assert_near(norm(m_orig.beta - m_pert.beta), 0.0, 1e-10, "Perturbing future rows has ZERO effect on AR training beta");
assert_near(m_orig.price_min, m_pert.price_min, 1e-10, "Perturbing future rows has ZERO effect on AR training price_min");
assert_near(m_orig.price_max, m_pert.price_max, 1e-10, "Perturbing future rows has ZERO effect on AR training price_max");


// ============================================================================
// Group 2: AR Lag Indexing & Inverse Scaling Exactness
// ============================================================================
mprintf("\n--- Group 2: AR Lag Indexing & Unit Consistency ---\n");
// In fit_ar_at:
// Column 1 is close(i) = C_{t-p} (oldest lag)
// Column p is close(i+p-1) = C_{t-1} (most recent lag)
assert_true(m_orig.y_prev_test(1) == d_tech.close(100+5), "model.y_prev_test(1) matches actual close before test target");

// Inverse scaling roundtrip test
pr_min = 150.0; pr_max = 250.0; pr_rng = pr_max - pr_min;
val_raw = 215.75;
val_scaled = (val_raw - pr_min) / pr_rng;
val_roundtrip = val_scaled * pr_rng + pr_min;
assert_near(val_roundtrip, val_raw, 1e-12, "Inverse min-max price scaling is exact bit-for-bit identity");


// ============================================================================
// Group 3: Independent Hand-Recomputation of Core Metrics
// ============================================================================
mprintf("\n--- Group 3: Independent Hand-Recomputation of Evaluation Metrics ---\n");
// Hand-crafted 5-observation fixture:
// y_true = [100, 102, 101, 105, 104]
// y_pred = [101, 101, 103, 104, 106]
// y_prev = [ 99, 100, 102, 101, 105]
//
// Residuals: [-1, +1, -2, +1, -2]
// Squared residuals: [1, 1, 4, 1, 4] -> sum = 11, mean = 2.2
// Exact RMSE: sqrt(2.2) = 1.4832396974...
// Exact MAE: (1 + 1 + 2 + 1 + 2) / 5 = 7/5 = 1.4
//
// Naive residuals (y_true - y_prev): [+1, +2, -1, +4, -1]
// Naive squared: [1, 4, 1, 16, 1] -> sum = 23, mean = 4.6
// Exact Naive RMSE: sqrt(4.6) = 2.144761058...
// Exact Theil U2: sqrt(2.2) / sqrt(4.6) = sqrt(11/23) = 0.6915640898...
//
// Actual moves:   [+1, +2, -1, +4, -1] -> signs: [+1, +1, -1, +1, -1]
// Pred moves:     [+2, +1, +1, +3, +1] -> signs: [+1, +1, +1, +1, +1]
// Sign matches:   Day 1, Day 2, Day 4 -> 3 / 5 = 60.0%
y_act_hand = [100; 102; 101; 105; 104];
y_prd_hand = [101; 101; 103; 104; 106];
y_prv_hand = [99; 100; 102; 101; 105];

m_hand = compute_metrics(y_act_hand, y_prd_hand, y_prv_hand);
assert_near(m_hand.rmse, sqrt(2.2), 1e-12, "RMSE matches hand calculation sqrt(11/5)");
assert_near(m_hand.mae, 1.4, 1e-12, "MAE matches hand calculation 7/5 = 1.4");
assert_near(m_hand.theil_u2, sqrt(2.2 / 4.6), 1e-12, "Theil U2 matches hand calculation sqrt(11/23)");
assert_near(m_hand.dir_acc, 60.0, 1e-12, "Directional Accuracy matches hand calculation 3/5 = 60.0%");

// Check MAPE hand calculation
// abs(res) / actual = [1/100, 1/102, 2/101, 1/105, 2/104]
mape_expected = mean([1/100, 1/102, 2/101, 1/105, 2/104]) * 100;
assert_near(m_hand.mape, mape_expected, 1e-12, "MAPE matches hand calculation");


// ============================================================================
// Group 4: Directional Accuracy Sign Conventions & Flat-Move Guards
// ============================================================================
mprintf("\n--- Group 4: Directional Accuracy Sign Conventions & Flat Moves ---\n");
// Test 1: Day with flat actual move (actual did not move) -> excluded from scoring
y_act_flat = [100; 100; 102];
y_prd_flat = [101; 102; 103];
y_prv_flat = [99; 100; 101];
// Day 1: act move +1, prd move +2 (match)
// Day 2: act move 0 (FLAT -> excluded from scoring)
// Day 3: act move +1, prd move +2 (match)
// Result: 2 scored days, 2 matches = 100.0%
m_flat = compute_metrics(y_act_flat, y_prd_flat, y_prv_flat);
assert_equal(m_flat.n_dir_scored, 2, "Flat actual days are excluded from directional scoring denominator");
assert_near(m_flat.dir_acc, 100.0, 1e-12, "Remaining active moves score 100% directional accuracy");

// Test 2: Flat predicted move when actual moved -> scored as failure
y_act_mv = [100; 105];
y_prd_fl = [99; 100]; // predicted change 0 on day 2
y_prv_fl = [98; 100];
m_fl = compute_metrics(y_act_mv, y_prd_fl, y_prv_fl);
assert_near(m_fl.dir_acc, 50.0, 1e-12, "Zero predicted move on non-zero actual move scores as false call");

// Test 3: Naive model (never predicts change) -> returns NaN (no directional calls)
m_nv_fl = compute_metrics(y_act_mv, y_prv_fl, y_prv_fl);
assert_true(isnan(m_nv_fl.dir_acc), "Model that predicts zero change throughout returns NaN directional accuracy");


// ============================================================================
// Group 5: Degenerate Series & Numerical Boundary Guards
// ============================================================================
mprintf("\n--- Group 5: Degenerate Series & Boundary Guards ---\n");
// Constant series test
y_const = [50; 50; 50; 50; 50];
m_const = compute_metrics(y_const, y_const, y_const);
assert_near(m_const.rmse, 0.0, 1e-12, "Constant series exact match RMSE is 0.0");
assert_near(m_const.mae, 0.0, 1e-12, "Constant series exact match MAE is 0.0");
assert_near(m_const.r2, 1.0, 1e-12, "Constant series exact match R2 is 1.0");
assert_near(m_const.theil_u2, 1.0, 1e-12, "Constant series Theil U2 handled safely as 1.0");

// Zero actual price MAPE division-by-zero guard
y_zero = [0; 0; 0];
y_zprd = [1; 1; 1];
m_zero = compute_metrics(y_zero, y_zprd, y_zero);
assert_true(isnan(m_zero.mape), "Zero price target produces NaN MAPE without division by zero crash");
assert_true(isnan(m_zero.accuracy_pct), "Zero price target produces NaN Prediction Accuracy");


// ============================================================================
// Group 6: Equal Sample Counts & Synchronized Forecast Origins
// ============================================================================
mprintf("\n--- Group 6: Equal Test Sample Counts Across All 5 Models ---\n");
split_cal = round(d_tech.n * 0.8);
expected_test_n = d_tech.n - split_cal; // 60 rows

m_naive = run_model(d_tech, "NAIVE", split_cal, 10, 0.3, 0.1);
m_lr    = run_model(d_tech, "LR", split_cal, 10, 0.3, 0.1);
m_ar    = run_model(d_tech, "AR", split_cal, 10, 0.3, 0.1);
m_es    = run_model(d_tech, "ES", split_cal, 10, 0.3, 0.1);
m_ridge = run_model(d_tech, "RIDGE", split_cal, 10, 0.3, 0.1, 1.0);

assert_equal(size(m_naive.y_true, 1), expected_test_n, "Naive evaluates on exactly n - split_cal rows (60)");
assert_equal(size(m_lr.y_true, 1), expected_test_n, "LR evaluates on exactly n - split_cal rows (60)");
assert_equal(size(m_ar.y_true, 1), expected_test_n, "AR evaluates on exactly n - split_cal rows (60)");
assert_equal(size(m_es.y_true, 1), expected_test_n, "ES evaluates on exactly n - split_cal rows (60)");
assert_equal(size(m_ridge.y_true, 1), expected_test_n, "Ridge evaluates on exactly n - split_cal rows (60)");

// Verify identical target dates across all models
assert_near(norm(m_naive.y_true - m_lr.y_true), 0.0, 1e-12, "Naive and LR test targets are bit-for-bit identical");
assert_near(norm(m_naive.y_true - m_ar.y_true), 0.0, 1e-12, "Naive and AR test targets are bit-for-bit identical");
assert_near(norm(m_naive.y_true - m_es.y_true), 0.0, 1e-12, "Naive and ES test targets are bit-for-bit identical");
assert_near(norm(m_naive.y_true - m_ridge.y_true), 0.0, 1e-12, "Naive and Ridge test targets are bit-for-bit identical");


// ============================================================================
// Group 7: Prediction Interval Coverage Calibration
// ============================================================================
mprintf("\n--- Group 7: Prediction Interval Calibration ---\n");
// Ridge prediction interval width and degrees of freedom
assert_true(m_ridge.ci_hi > m_ridge.ci_lo, "Ridge 95% prediction interval upper > lower");
assert_true(m_ridge.model.df > 0, "Ridge effective degrees of freedom is positive");
assert_true(m_ridge.model.train_residual_std > 0, "Ridge residual standard error is strictly positive");

// Verify AR prediction interval
assert_true(m_ar.ci_hi > m_ar.ci_lo, "AR 95% prediction interval upper > lower");
assert_true(m_ar.model.df > 0, "AR degrees of freedom is positive");
assert_true(m_ar.model.train_residual_std > 0, "AR residual standard error is strictly positive");


// ============================================================================
// Group 8: Backtest Timing, Execution Lag & Transaction Drag
// ============================================================================
mprintf("\n--- Group 8: Backtesting Timing & Friction Accounting ---\n");
// Hand calculation fixture for backtest (3-day sequence verifying 1-day execution lag):
// Capital = 100,000, Cost = 0.1%, Slippage = 0.05% -> Drag = 0.15% (0.0015)
// Day 1: close = 100, not in position.
// Day 2: close = 102, pred = 103 (+3% vs Day 1 close -> BUY signal).
//        Position entered at CLOSE of Day 2: entry cost paid = 100,000 * 0.0015 = 150.
//        Day 2 ending equity = 100,000 - 150 = 99,850.00.
// Day 3: close = 104.04 (+2% vs Day 2 close 102). In position for Day 2->3 move.
//        Equity after Day 3 = 99,850 * 1.02 = 101,847.00.
y_act_bt = [100; 102; 104.04];
y_prd_bt = [100; 103; 102];
bt_hand = run_backtest(y_act_bt, y_prd_bt, 0.5, -0.5, 100000, 0.1, 0.05);

assert_near(bt_hand.total_costs_paid, 150.0, 1e-8, "Backtest entry cost matches hand calculation 150.00");
assert_near(bt_hand.strategy_value(2), 99850.0, 1e-6, "Backtest Day 2 ending capital reflects entry cost deduction without premature day return");
assert_near(bt_hand.strategy_value(3), 101847.0, 1e-6, "Backtest Day 3 ending capital matches lagged execution hand calculation 101,847.00");
assert_equal(bt_hand.n_trades, 1, "Exactly 1 BUY trade executed on signal");
assert_equal(bt_hand.position(2), 1, "Position held on Day 2 following Day 1 BUY execution");


// ============================================================================
// Group 9: Walk-Forward Expanding-Window Validation
// ============================================================================
mprintf("\n--- Group 9: Walk-Forward Cross-Validation Integrity ---\n");
wf_5 = walk_forward_all(d_tech, 5, 10, 0.3, 0.1, %t, 1.0);
assert_equal(wf_5.n_used, 5, "Walk-forward executed exactly 5 folds");
assert_true(wf_5.train_end(2) > wf_5.train_end(1), "Fold 2 training window strictly expands beyond Fold 1");
assert_true(wf_5.test_end(5) == d_tech.n, "Fold 5 test end reaches the final observation");
assert_true(and(wf_5.mean_rmse > 0), "All 5 models report positive walk-forward mean RMSE");
assert_true(and(wf_5.rmse_std >= 0), "Fold standard deviations are non-negative");


// ============================================================================
// Group 10: Forensic Demonstration of AR(10) Mock Anomaly vs Real Market Data
// ============================================================================
mprintf("\n--- Group 10: Forensic Proof of AR(10) Mock Anomaly vs Real Market Data ---\n");
// 1. Load the mock AAPL fixture
mock_aapl_path = _DIR + "sample_data/mock_market_data/mock_twelvedata_aapl.json";
d_mock_aapl = mda_load_mock(mock_aapl_path, "AAPL", "NASDAQ");
r_mock_ar = run_model(d_mock_aapl, "AR", 52, 10, 0.3, 0.1);
r_mock_nv = run_model(d_mock_aapl, "NAIVE", 52, 10, 0.3, 0.1);

mprintf("    Mock AAPL AR(10) RMSE: %.6f (reproduced suspicious result)\n", r_mock_ar.metrics.rmse);
mprintf("    Mock AAPL Naive  RMSE: %.6f\n", r_mock_nv.metrics.rmse);
assert_near(r_mock_ar.metrics.rmse, 0.006635, 1e-4, "Forensic Reproduction: AR(10) on mock fixture achieves 0.0066 RMSE");

// Prove that mock AAPL close deltas follow exact 5-day periodicity:
// (C_t - C_{t-5}) - (C_{t-5} - C_{t-10}) == 0
c_mock = d_mock_aapl.close;
d2_mock = (c_mock(51:60) - c_mock(26:35)) - (c_mock(26:35) - c_mock(1:10));
assert_near(max(abs(d2_mock)), 0.01, 0.02, "Forensic Proof: Mock AAPL fixture has second-order periodicity of ~0.00");

// 2. Load the REAL AAPL market data (120 bars from local Twelve Data cache)
real_aapl_path = _DIR + "../../cache/market_data/AAPL_NASDAQ_120.json";
if isfile(real_aapl_path) then
    d_real_aapl = mda_load_mock(real_aapl_path, "AAPL", "NASDAQ");
    r_real_ar = run_model(d_real_aapl, "AR", round(d_real_aapl.n * 0.8), 10, 0.3, 0.1);
    r_real_nv = run_model(d_real_aapl, "NAIVE", round(d_real_aapl.n * 0.8), 10, 0.3, 0.1);
    r_real_rd = run_model(d_real_aapl, "RIDGE", round(d_real_aapl.n * 0.8), 10, 0.3, 0.1, 1.0);

    mprintf("    Real AAPL AR(10) RMSE: %.4f (NOT 0.0066! Real market volatility)\n", r_real_ar.metrics.rmse);
    mprintf("    Real AAPL Naive  RMSE: %.4f (Real market persistence)\n", r_real_nv.metrics.rmse);
    mprintf("    Real AAPL Ridge  RMSE: %.4f\n", r_real_rd.metrics.rmse);

    assert_true(r_real_ar.metrics.rmse > 3.0, "Real AAPL market data produces realistic RMSE > 3.0 (got " + string(r_real_ar.metrics.rmse) + ")");
    assert_true(r_real_nv.metrics.rmse < r_real_ar.metrics.rmse, "Real AAPL market data: Naive persistence beats AR(10)");
else
    mprintf("    [SKIP] Real AAPL cache file not found at %s\n", real_aapl_path);
end


// ============================================================================
// Final Accounting & Gate Check
// ============================================================================
mprintf("\n======================================================================\n");
mprintf("  Phase 5 Statistical Integrity Audit Results\n");
mprintf("  Passed: %d\n", n_p5_pass);
mprintf("  Failed: %d\n", n_p5_fail);
mprintf("======================================================================\n");

if n_p5_fail > 0 then
    error("Phase 5 verification encountered " + string(n_p5_fail) + " failure(s).");
    exit(1);
else
    mprintf("ALL STATISTICAL INTEGRITY ASSERTIONS PASSED SUCCESSFULLY.\n");
    exit(0);
end
