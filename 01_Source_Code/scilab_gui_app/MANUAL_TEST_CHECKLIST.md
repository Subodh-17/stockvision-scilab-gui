# StockVision manual test checklist (integrated dashboard)

Run from this folder in Scilab: `exec("gui_app.sce", -1);`
Recommended window: about 1500 x 980 px (the window shrinks to the screen; text panels then scroll).

Automated coverage that does **not** replace this list:
`test_model_engine.sce` (engine, no display needed) and `test_gui_workflow.sce` (drives the real
GUI callbacks; needs a display, e.g. `xvfb-run -a scilab -nw -nb -f test_gui_workflow.sce`).

## A. Launch and single-window rule
- [ ] The app opens **one** figure window with title band, left controls, and panels for price chart,
      info (Data Quality / Assumptions tabs), model results, comparison + ranking, comparison chart,
      equity curve, backtest summary and walk-forward.
- [ ] Charts/results panels show "No analysis yet" / "No comparison yet" / "No backtest yet".
- [ ] Run Backtest and Export Results are greyed out; Run Analysis, Compare Models, Walk Forward are enabled.
- [ ] Status bar reads "Ready. ..."; no popup appeared.

## B. Data quality
- [ ] Info panel, *Data Quality* tab: rows, date range, missing values, duplicate dates,
      chronological order, invalid OHLC rows, training rows, testing rows (numbers match the dataset).
- [ ] Move the split slider: training/testing rows change immediately; any earlier results are cleared.
- [ ] File > Load Custom CSV > `sample_data/messy_demo_data_quality.csv`: Chronological order = NO (sorted on load),
      Invalid OHLC rows = 1, "1 rows dropped on load" (118 rows kept of 120).
- [ ] A CSV with a wrong header or a duplicate date shows an error dialog and the app stays usable.

## C. Single-model analysis (repeat for each model)
- [ ] Choose Linear Regression, AR Time-Series, Exponential Smoothing; click **Run Analysis**.
- [ ] Status shows "Training ...", "Updating dashboard...", then "Analysis complete." (green).
- [ ] Main chart (inside the main window) shows training context, actual, predicted, 20-day MA,
      train/test divider and the next-day forecast marker; the colour key above it matches.
- [ ] Model Results lists model, prediction, current close, signal, test RMSE, MAE, MAPE, R^2, direction accuracy,
      naive RMSE and the "beats / does NOT beat naive" verdict, train/test samples, model status (READY).
- [ ] Toggle "Show 20-day moving average": the MA line appears/disappears without re-running.
- [ ] Changing the model clears results (status says so) and disables Run Backtest / Export.

## D. Compare Models and ranking
- [ ] Click **Compare Models**. Table shows Naive, LR, AR, ES for RMSE, MAE, MAPE, R^2, direction accuracy,
      walk-forward RMSE/MAE; best value per row is green with `*`.
- [ ] Ranking lists mean ranks, the best StockVision model with a reason, RMSE vs naive, and a plain
      statement when no model beats the naive baseline.
- [ ] Bar chart shows test-window RMSE and walk-forward mean RMSE per model, inside the main window.
- [ ] Model Status becomes VALIDATED once walk-forward has run.

## E. Walk-forward validation
- [ ] Click **Walk Forward Validation**: one row per fold with test-row range and RMSE per model, plus
      mean RMSE, mean MAE, mean direction accuracy.
- [ ] Load `messy_demo_data_quality.csv` (118 rows), set folds to 10, click Walk Forward Validation: the panel says 7 folds were used and why.
- [ ] Set folds to 3 and 6: the fold count in the panel follows.

## F. Backtest vs buy and hold
- [ ] Run Analysis, then **Run Backtest**; the Info panel switches to *Assumptions*.
- [ ] Summary strip and panel show starting/ending capital, total and annualized return, max drawdown,
      volatility, Sharpe, trades, winning/losing, win rate, strategy vs buy and hold, same test period.
- [ ] Equity chart shows both curves and BUY/SELL markers.
- [ ] Change transaction cost or slippage: the backtest is cleared and the assumptions panel updates;
      re-running with higher costs lowers the ending capital.
- [ ] Enter `abc` as a threshold: red status-bar message, no crash, no popup.

## G. Export
- [ ] **Export Results** > `.txt`: report with data quality, parameters, results, comparison, ranking,
      walk-forward, assumptions, backtest, timestamp, plus `_predictions.csv`, `_comparison.csv`,
      `_walkforward.csv`, `_backtest.csv` next to it.
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
