---
title: "StockVision - Project Report"
subtitle: "Technical report (V2) | Scilab GUIVerse Hackathon"
---

# 1. Purpose and scope

StockVision is an educational Scilab application for stock analysis and prediction. This report documents the V2 design, the evaluation protocol, the results on the bundled synthetic data, how the work was verified, and what remains limited. It is written to be checkable: every number in it comes from a program run included in the submission.

![Final integrated dashboard.](05_GUI_Screenshots/09_Final_Dashboard.png){width=100%}

# 2. System overview

**Architecture.** `model_engine.sce` contains all data loading, validation, modelling, metrics, ranking, walk-forward, backtest, text-report and export logic, with no GUI code, so it runs headless and is unit-tested. `gui_app.sce` builds one figure, holds application state, calls the engine, and renders. The three charts are `newaxes` axes inside the same figure as the controls; text panels are listboxes. Because a chart refresh deletes only that axes' children, no operation can destroy the controls.

**State handling.** Results are held in one state structure: analysis, comparison (including walk-forward) and backtest. Each setting change invalidates only what it affects: dataset, split, AR lookback -> everything; model -> analysis and backtest; fold count -> comparison; thresholds, capital, cost, slippage -> backtest. Buttons that depend on results are disabled until they exist.

# 3. Models

- **Linear Regression.** Features at day *t* (open, high, low, close, volume, 1-day return, 5- and 10-day moving averages, 5-day volatility, lagged closes 1-3) predict the close at *t+1*. Features are standardized with training-period mean and standard deviation; coefficients come from least squares (`\`).
- **AR(p).** The last *p* closes (default 10) predict the next close. Prices are scaled with the training-period minimum and maximum; coefficients come from least squares. This is a linear model, not an LSTM or any neural network.
- **Holt exponential smoothing.** Level and trend recursions with fixed alpha = 0.3, beta = 0.1; the forecast for day *t* is level + trend from days before *t*. Parameters are not fitted.
- **Naive baseline.** Forecast for day *t* = close of day *t-1*.

# 4. Evaluation protocol

All four models share the dataset, chronological split, target and test window: train on calendar rows `1..split_cal`, test on `split_cal+1..n`. The test window therefore contains the same dates for every model (V1 gave LR and AR a slightly different window; this was corrected and is covered by a test). Metrics: RMSE, MAE, MAPE, R^2 and directional accuracy (sign agreement of predicted and actual moves, zero-move days excluded, not defined for the naive forecast).

**Ranking.** Mean rank over six metrics (test RMSE, MAE, MAPE, direction accuracy, walk-forward RMSE and MAE), tie-break by walk-forward RMSE then test RMSE. R^2 is shown but not ranked (on one window it is a monotone function of RMSE). Models lacking a metric skip it. A near-tie flag appears if the top two StockVision models differ by under 1% RMSE. The ranking never favours a model a priori and may place the naive baseline first.

**Walk-forward.** Expanding window, first training block `max(40% of rows, 40, lookback + 30)`, at least 10 test rows per fold, default 5 folds. Each fold is evaluated on data truncated at the fold's end. If the data cannot support the requested folds, the count is reduced and the reason displayed; with too little data for one fold the request is refused.

# 5. Leakage controls and the evidence for them

| Control | Evidence (automated check) |
|----------------|------------------------------|
| Scaling/fit from training rows only | LR coefficients, mean and std unchanged when test-period prices are altered |
| Forecast for day *t* uses data to *t-1* | Multiplying every price after day *k* by 1.7 leaves all four models' forecasts up to *k* unchanged |
| Folds never see their future | Fold models run on truncated data (same forecasts as full data up to the cut); altering the last fold leaves folds 1-4 unchanged |
| Signal cannot earn a return that already happened | Hand-built scenario: a day-2 BUY earns only the day-3 and day-4 returns |
| Chronological order | Newest-first files are sorted ascending and flagged; duplicate dates rejected |
| Common test window | Targets, previous closes and dates identical across all four models |

# 6. Backtest design

Long-only, all-in/all-out simulation over the test window. The day's return is booked before that day's signal is evaluated; a signal from data through day T trades at the close of T+1 and first earns the T+1 to T+2 return. Transaction cost and slippage (percent of equity) are deducted on every executed BUY and SELL. Trade returns are reported net of both costs. **Buy and hold** is invested from the first day of the same window and pays one entry cost. Maximum drawdown, annualized volatility and Sharpe (252 bars, risk-free rate 0) are computed identically for both curves; annualized return is shown only for windows of at least 30 days and is labelled an extrapolation.

# 7. Results on the bundled synthetic data

Settings: 80/20 split, AR lookback 10, ES 0.3/0.1, 5 folds, BUY >= +0.5%, SELL <= -0.5%, cost 0.1%, slippage 0.05%. Output of `generate_sample_outputs.sce`; lower RMSE is better.

| Dataset (synthetic) | Metric | Naive | LR | AR | ES |
|---|---|---|---|---|---|
| Tech Growth Stock | Test RMSE | 2.5810 | 2.7308 | 2.6780 | 3.1123 |
| | Walk-forward mean RMSE | 2.4551 | 2.5608 | 2.5355 | 3.2314 |
| Blue Chip Stock | Test RMSE | 1.6822 | 1.7692 | 1.7775 | 2.7713 |
| | Walk-forward mean RMSE | 1.8542 | 2.0941 | 2.1382 | 2.6448 |
| Volatile Stock | Test RMSE | 5.6014 | 6.7955 | 6.5915 | 8.3150 |
| | Walk-forward mean RMSE | 3.7203 | 4.0955 | 3.9121 | 5.1572 |


- **Tech Growth Stock**: best StockVision model by mean rank = AR -- best on Test MAE, Test MAPE; No StockVision model beat the naive baseline on test RMSE.
- **Blue Chip Stock**: best StockVision model by mean rank = LR -- best on Direction accuracy; No StockVision model beat the naive baseline on test RMSE.
- **Volatile Stock**: best StockVision model by mean rank = AR -- best on Direction accuracy; No StockVision model beat the naive baseline on test RMSE.

Full output for the Tech Growth dataset (best value per row marked `*`):

```
60 test rows, 5 WF folds; * = best in row
Metric               Naive       LR       AR       ES
-----------------------------------------------------
RMSE               2.5810*   2.7308   2.6780   3.1123
MAE                 2.0432   2.0971  2.0272*   2.4523
MAPE                1.287%   1.325%  1.280%*   1.541%
R^2                0.9032*   0.8916   0.8958   0.8592
Direction acc.         n/a    55.0%    50.0%   56.7%*
Walk-fwd RMSE      2.4551*   2.5608   2.5355   3.2314
Walk-fwd MAE       1.9725*   2.0630   2.0380   2.5220
 
MODEL RANKING (mean rank over 6 metrics; lower = better)
1. AR 1.83   2. LR 2.83   3. ES 3.50   | Naive 1.40
Best StockVision model: AR -- best on Test MAE, Test MAPE
RMSE vs naive:  LR -5.8%  AR -3.8%  ES -20.6%
No StockVision model beat the naive baseline on test RMSE.
 
Walk-forward:
Expanding window: train on all earlier rows, test on the next block.
Folds: 5 used (5 requested); first train block 120 rows.
Fold Test rows       Naive       LR       AR       ES  (RMSE)
1    121-156       1.9706*   2.1187   2.0607   2.2620
2    157-192        1.9804   1.8091  1.7954*   2.3996
3    193-228       3.1538*   3.4471   3.3060   4.7614
4    229-264       2.9308*   3.2496   3.3378   3.9817
5    265-300        2.2399   2.1796  2.1777*   2.7525
-----------------------------------------------------
Mean RMSE          2.4551*   2.5608   2.5355   3.2314
Mean MAE           1.9725*   2.0630   2.0380   2.5220
Mean Dir. acc.         n/a   53.9%*    51.1%    53.3%
```

Backtest of the Linear Regression signals on Tech Growth:

```
                           Strategy   Buy & Hold
Starting capital          100000.00    100000.00
Ending capital            114211.66    111150.20
Total return                +14.21%      +11.15%
Annualized return*           +76.4%       +57.1%
Max drawdown                  7.63%        7.63%
Volatility (ann.)            25.86%       26.43%
Sharpe (rf=0)                  2.32         1.86
Trades executed: 1   Round trips: 0
Winning: 0   Losing: 0   Win rate: n/a
Strategy is AHEAD of buy & hold by 3.06 pts.
Position still open at the end (not a trade).
* annualized from 59 days: short-window extrapolation
```

**Reading these results honestly.** On all three datasets the naive baseline has the lowest test RMSE and the lowest walk-forward RMSE and MAE. On Tech Growth, AR has marginally lower single-split MAE and MAPE (the `*` marks in the table above); on the other two datasets the naive baseline is best on every single-split error metric. Directional accuracy is at or below 50% in several cases. This is consistent with price series that are close to a random walk, although the statistical properties of the bundled data were not tested formally. In this illustrative backtest, the strategy returned 14.21% versus 11.15% for buy-and-hold. The result is based on a single trade (one BUY, still open at the end of the 59-day window) and should not be interpreted as evidence of predictive superiority. The value of the application is that it makes comparisons like these visible.

# 8. Verification

| Check | Result |
|--------------|--------------|
| Engine tests (`test_model_engine.sce`) | 263 checks, 0 failures (Scilab 2024.0.0) |
| GUI workflow test (`test_gui_workflow.sce`, live GUI on a virtual display) | 41 checks, 0 failures |
| Sample-output regeneration | identical numbers (timestamp only differs) |
| Original V1 checks | retained inside the new engine suite (and previously run unchanged against the rewritten engine); all pass |

The GUI test confirms exactly one graphics window after analyses, comparison, backtest and exports; stale results are cleared on dataset, split, lookback, model, fold, and cost changes; buttons are disabled when prerequisites are missing; invalid inputs yield status-bar messages; exports never overwrite; reset restores defaults; a bad CSV fails cleanly. **Not verified:** Windows or other Scilab versions, very small screens, screen readers, and appearance beyond the captured screenshots.

# 9. Response to the hackathon feedback

| Feedback theme | Change | Where to see it |
|----------|---------------------|-----------|
| Plots/results in separate windows | Charts embedded in the main figure; results in panels; no extra windows | Screenshots 03-09; GUI test (one window) |
| Lengthy source comments | Verbose comment blocks substantially reduced and replaced with short purpose and assumption notes | Source files |
| Comparison with other submissions | Same-window four-way comparison, walk-forward, ranking, baseline verdicts, data-quality summary, richer export | Section 4; screenshots 06, 08 |
| Simplified modelling/backtesting assumptions | Assumptions panel; naive baseline; buy-and-hold benchmark; costs on every trade; execution lag tests; Model Info limitations | Section 6; screenshot 07 |

# 10. Limitations and future work

Synthetic data only; single split for headline metrics and noisy short test windows; no significance testing; fixed ES parameters and an untuned AR lookback; no regularization for LR; long/cash backtest without spreads or market impact; PDF export covers the three charts only. Possible next steps: real historical data, expanding hyperparameter search inside walk-forward folds, bootstrap confidence intervals on metric differences, regularized regression, and testing on additional Scilab versions and platforms.
