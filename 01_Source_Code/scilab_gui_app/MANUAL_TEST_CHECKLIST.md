# StockVision V3 manual test checklist (integrated dashboard)

Run from this folder in Scilab: `exec("gui_app.sce", -1);`
Recommended window: about 1500 x 980 px (the window shrinks to the screen; text panels then scroll).

Automated coverage that does **not** replace this list:
`test_model_engine.sce` (311 checks, 0 failures on Scilab 2026.1.0) and `test_gui_workflow.sce` (45 checks, 0 failures,
drives the real GUI callbacks and graphics contexts).

## A. Launch and single-window rule
- [ ] The app opens **one** figure window with title band ("STOCKVISION V3"), left controls, and panels for price chart,
      info (Data Quality / Assumptions / Interpretation tabs), model results, comparison + ranking, comparison chart,
      equity curve, backtest summary and walk-forward.
- [ ] Charts/results panels show "No analysis yet" / "No comparison yet" / "No backtest yet".
- [ ] Run Backtest and Export Results are greyed out; Run Analysis, Compare Models, Walk Forward are enabled.
- [ ] Status bar reads "Ready. ..."; no popup appeared.

## B. Data quality & anomaly flags
- [ ] Info panel, *Data Quality* tab: rows, date range, missing values, duplicate dates,
      chronological order, invalid OHLC rows, training rows, testing rows (numbers match the dataset).
- [ ] Anomaly detection: Non-fatal price jumps (>50%), zero-volume bars, and date gaps (>14 days) are displayed.
- [ ] Move the split slider: training/testing rows change immediately; any earlier results are cleared.
- [ ] File > Load Custom CSV > `sample_data/messy_demo_data_quality.csv`: Chronological order = NO (sorted on load),
      Invalid OHLC rows = 1, "1 rows dropped on load" (118 rows kept of 120).
- [ ] A CSV with a wrong header or a duplicate date shows an error dialog and the app stays usable.

## C. Single-model analysis (repeat for each model)
- [ ] Choose Linear Regression, AR Time-Series, Exponential Smoothing; click **Run Analysis**.
- [ ] Status shows "Training ...", "Updating dashboard...", then "Analysis complete." (green).
- [ ] Main chart shows training context, actual, predicted, 20-day MA, train/test divider, next-day forecast marker,
      and exact **95% prediction interval whiskers**; the colour key above it matches.
- [ ] Model Results lists model, prediction with 95% interval [ci_lo, ci_hi], current close, signal, test RMSE, MAE, MAPE, R^2, direction accuracy,
      naive RMSE and the "beats / does NOT beat naive" verdict, train/test samples, model status (READY).
- [ ] Toggle "Show 20-day moving average": the MA line appears/disappears without re-running.
- [ ] Changing the model clears results (status says so) and disables Run Backtest / Export.

## D. Compare Models, ranking & research interpretation
- [ ] Click **Compare Models**. Table shows Naive, LR, AR, ES for RMSE, MAE, MAPE, R^2, direction accuracy,
      walk-forward RMSE/MAE; best value per row is green with `*`.
- [ ] Ranking lists mean ranks, primary ranking metric (RMSE), tie-break rule, best StockVision model with reasons,
      RMSE vs naive, and an honest statement when naive wins.
- [ ] Bar chart shows test-window RMSE and walk-forward mean RMSE per model, inside the main window.
- [ ] Switch to the **Interpretation** tab on the Info panel: displays dynamic quantitative research commentary
      covering model ranking, naive comparison, directional timing, sample power, walk-forward regime variation,
      and methodological limitations.
- [ ] Model Status becomes VALIDATED once walk-forward has run.

## E. Walk-forward validation
- [ ] Click **Walk Forward Validation**: one row per fold with test-row range and RMSE per model, plus
      mean RMSE, mean MAE, fold RMSE std dev, total evaluated observations count.
- [ ] Load `messy_demo_data_quality.csv` (118 rows), set folds to 10, click Walk Forward Validation: the panel says 7 folds were used and why.
- [ ] Set folds to 3 and 6: the fold count in the panel follows.

## F. Backtest vs buy and hold
- [ ] Run Analysis, then **Run Backtest**; the Info panel switches to *Assumptions*.
- [ ] Summary strip and panel show starting/ending capital, total and annualized return, max drawdown,
      volatility, Sharpe, Calmar ratio, market exposure %, cumulative costs paid, trades, winning/losing, win rate,
      strategy vs buy and hold over identical period.
- [ ] Equity chart shows both curves and BUY/SELL markers.
- [ ] Change transaction cost or slippage: the backtest is cleared and the assumptions panel updates;
      re-running with higher costs lowers ending capital and increases cumulative costs paid.
- [ ] Enter `abc` as a threshold: red status-bar message, no crash, no popup.

## G. Export
- [ ] **Export Results** > `.txt`: report with V3 branding, Scilab platform version, data quality, parameters, results,
      exact 95% prediction intervals, comparison, ranking, walk-forward dispersion, assumptions, backtest realism metrics,
      dynamic research interpretation, plus companion CSV tables (`_predictions.csv`, `_comparison.csv`,
      `_walkforward.csv`, `_backtest.csv`) next to it.
- [ ] Exporting twice to the same name creates `_2` files; nothing is overwritten.
- [ ] `.csv` gives the single Metric,Value table; `.pdf` gives the three charts only (no text panels or colour key).

## H. Reset, Model Info, stale state
- [ ] **Model Info** opens a dialog describing the selected model (assumptions, limitations; AR states it is not an LSTM).
- [ ] **Reset** restores dataset, model, split 80/20, lookback 10, folds 5, thresholds, costs and clears all panels.
- [ ] After any of: dataset change, split change, lookback change -> all results cleared.
      Fold change -> comparison cleared only. Cost/threshold change -> backtest cleared only.

## I. Capturing the required screenshots (if repeating by hand)
Use a window of about 1500 x 980 and the Tech Growth dataset unless stated. Capture the whole window.

| File | Steps |
|---|---|
| 01_Main_GUI.png | Launch; capture before clicking anything. |
| 02_Data_Quality.png | File > Load Custom CSV > `messy_demo_data_quality.csv`; Data Quality tab. |
| 03_Linear_Regression_Integrated.png | Reset; model = Linear Regression; Run Analysis. |
| 04_AR_Time_Series_Integrated.png | Model = AR Time-Series; Run Analysis. |
| 05_Exponential_Smoothing_Integrated.png | Model = Exponential Smoothing; Run Analysis. |
| 06_Model_Comparison_Integrated.png | Reset; Compare Models. |
| 07_Backtest_Integrated.png | Reset; Run Analysis; Run Backtest. |
| 08_Walk_Forward_Validation.png | Reset; dataset = Volatile; folds = 6; Walk Forward Validation. |
| 09_Final_Dashboard.png | Reset; Run Analysis; Compare Models; Run Backtest. |

The committed screenshots were produced automatically with `tools/capture_screens.sce` on a virtual display
(Scilab 2024.0.0, Linux). `xs2png` does not capture uicontrols, so a screen capture is required.
