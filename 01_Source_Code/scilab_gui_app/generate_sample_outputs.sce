// Generates genuine sample outputs by running the real, tested engine
// against all 3 bundled datasets with all THREE models -- these are real
// computed numbers, not fabricated placeholders. Re-run this any time
// model_engine.sce changes, and copy the console output into
// outputs/sample_outputs.txt so that file never drifts out of sync with
// what the engine actually produces.
clear; clc;
exec("model_engine.sce", -1);

ES_ALPHA = 0.3; ES_BETA = 0.1;   // same defaults as gui_app.sce

datasets = ["sample_data/tech_growth_stock.csv", "sample_data/blue_chip_stock.csv", ..
            "sample_data/volatile_stock.csv"];
labels = ["Tech Growth Stock (synthetic demo data)", "Blue Chip Stock (synthetic demo data)", ..
          "Volatile Stock (synthetic demo data)"];

for i = 1:size(datasets, 2)
    mprintf("\n========================================\n");
    mprintf("Dataset: %s\n", labels(i));
    mprintf("========================================\n");
    data = load_dataset(datasets(i));
    current_price = data.close($);
    mprintf("Rows: %d | Current price: %.2f\n", data.n, current_price);
    if size(data.warnings, 1) > 0 then
        mprintf("Load warnings: %s\n", strcat(data.warnings, " | "));
    end

    feat = build_lr_features(data);
    lr_model = fit_linear_regression(feat, 0.8);
    lr_eval = evaluate_model(lr_model);
    [lr_next, lr_ci_lo, lr_ci_hi] = predict_next_lr(lr_model);
    lr_sig = generate_signal(current_price, lr_next, 0.5, -0.5);
    mprintf("\n-- Linear Regression --\n");
    mprintf("RMSE: %.4f  MAE: %.4f  MAPE: %.2f%%  R^2: %.4f  Accuracy: %.2f%%\n", ..
            lr_eval.rmse, lr_eval.mae, lr_eval.mape, lr_eval.r2, lr_eval.accuracy_pct);
    mprintf("Predicted next close: %.2f (rough 95%% band %.2f-%.2f, %.2f%% change) -> Signal: %s\n", ..
            lr_next, lr_ci_lo, lr_ci_hi, lr_sig.pct_change, lr_sig.action);

    ar_model = fit_ar_model(data, 10, 0.8);
    ar_eval = evaluate_ar_model(ar_model);
    [ar_next, ar_ci_lo, ar_ci_hi] = predict_next_ar(ar_model);
    ar_sig = generate_signal(current_price, ar_next, 0.5, -0.5);
    mprintf("\n-- AR(10) Time-Series (linear, NOT an LSTM) --\n");
    mprintf("RMSE: %.4f  MAE: %.4f  MAPE: %.2f%%  R^2: %.4f  Accuracy: %.2f%%\n", ..
            ar_eval.rmse, ar_eval.mae, ar_eval.mape, ar_eval.r2, ar_eval.accuracy_pct);
    mprintf("Predicted next close: %.2f (rough 95%% band %.2f-%.2f, %.2f%% change) -> Signal: %s\n", ..
            ar_next, ar_ci_lo, ar_ci_hi, ar_sig.pct_change, ar_sig.action);

    es_model = fit_exponential_smoothing(data, 0.8, ES_ALPHA, ES_BETA);
    es_eval = evaluate_es_model(es_model);
    [es_next, es_ci_lo, es_ci_hi] = predict_next_es(es_model);
    es_sig = generate_signal(current_price, es_next, 0.5, -0.5);
    mprintf("\n-- Exponential Smoothing (Holt, alpha=%.1f, beta=%.1f) --\n", ES_ALPHA, ES_BETA);
    mprintf("RMSE: %.4f  MAE: %.4f  MAPE: %.2f%%  R^2: %.4f  Accuracy: %.2f%%\n", ..
            es_eval.rmse, es_eval.mae, es_eval.mape, es_eval.r2, es_eval.accuracy_pct);
    mprintf("Predicted next close: %.2f (rough 95%% band %.2f-%.2f, %.2f%% change) -> Signal: %s\n", ..
            es_next, es_ci_lo, es_ci_hi, es_sig.pct_change, es_sig.action);

    mprintf("\n-- 3-fold walk-forward validation (more robust than one split) --\n");
    wf_lr = walk_forward_validate(data, "LR", 3, 10);
    wf_ar = walk_forward_validate(data, "AR", 3, 10);
    wf_es = walk_forward_validate_es(data, 3, ES_ALPHA, ES_BETA);
    mprintf("LR:  mean RMSE %.4f | mean R^2 %.4f\n", wf_lr.mean_rmse, wf_lr.mean_r2);
    mprintf("AR:  mean RMSE %.4f | mean R^2 %.4f\n", wf_ar.mean_rmse, wf_ar.mean_r2);
    mprintf("ES:  mean RMSE %.4f | mean R^2 %.4f\n", wf_es.mean_rmse, wf_es.mean_r2);

    mprintf("\n-- Backtest (Linear Regression signal, starting capital 100000, no costs) --\n");
    bt = run_backtest(lr_model.y_test, lr_eval.y_pred, 0.5, -0.5, 100000);
    mprintf("Trades: %d (%d completed) | Strategy final: %.2f (%.2f%%) | Buy&Hold final: %.2f (%.2f%%)\n", ..
            bt.n_trades, bt.n_completed_trades, bt.strategy_final, bt.strategy_return_pct, ..
            bt.buyhold_final, bt.buyhold_return_pct);
    mprintf("Max drawdown: %.2f%% | Annualized volatility: %.2f%%\n", ..
            bt.max_drawdown_pct, bt.volatility_pct_annualized);

    mprintf("\n-- Same backtest with 0.1%% transaction cost + 0.05%% slippage per trade --\n");
    bt_cost = run_backtest(lr_model.y_test, lr_eval.y_pred, 0.5, -0.5, 100000, 0.1, 0.05);
    mprintf("Strategy final: %.2f (%.2f%%)\n", bt_cost.strategy_final, bt_cost.strategy_return_pct);
end
