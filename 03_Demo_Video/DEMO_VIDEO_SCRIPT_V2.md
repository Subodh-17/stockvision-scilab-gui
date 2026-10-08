# Demo video V2 - what was recorded, and an optional voice-over script

`Scilab_demo_video.mp4` is a real screen recording of the running Scilab GUI (1:48, under the 2:00 limit),
captured from a virtual display while `tools/record_demo.sce` drove the dashboard's own callbacks on a timed
schedule. Captions are burned in on a bar beneath the GUI. There is **no voice-over** and the mouse cursor is
only incidental, because the actions were issued by script, not by hand.

## Timeline (approximate, +/- 2 s)

| Time | On screen | Caption |
|---|---|---|
| 0:00-0:09 | Empty dashboard, "No analysis yet" states | StockVision - one window |
| 0:09-0:14 | Data Quality tab (Tech Growth) | Data quality before modelling |
| 0:14-0:22 | Load `messy_demo_data_quality.csv` | Sorted on load, bad rows dropped and counted |
| 0:22-0:25 | Reset | Defaults restored |
| 0:25-0:40 | Linear Regression, Run Analysis | Chart, metrics and forecast inside the main GUI |
| 0:40-0:48 | AR, Run Analysis | Linear, short-memory; not an LSTM |
| 0:48-0:56 | Exponential Smoothing, Run Analysis | Holt, fixed alpha and beta |
| 0:56-1:16 | Compare Models | Same window + naive baseline; best per metric highlighted; ranking |
| 1:16-1:34 | Run Backtest | Buy and hold, costs, slippage, lag; assumptions visible |
| 1:34-1:41 | Walk Forward Validation | Chronological folds, no future data |
| 1:41-1:48 | Final dashboard | No separate chart windows |

## Optional voice-over (to re-record with narration)

1. "StockVision is a Scilab dashboard for stock analysis and prediction. Everything you see - controls, charts, metrics - is in one window."
2. "Before modelling, a data-quality panel reports rows, date range, missing values, duplicates, ordering and invalid bars. Here a messy file is sorted and a bad row dropped and counted."
3. "Run Analysis fits Linear Regression. The chart, forecast, metrics and a naive-baseline check appear in the main window."
4. "Now the autoregressive model - a linear, short-memory model, not an LSTM - and Holt exponential smoothing."
5. "Compare Models puts Naive, LR, AR and ES on the same data and test window. The best value per metric is highlighted and the ranking is computed from the numbers. On this synthetic data, no model beats the naive baseline, and the app says so."
6. "The backtest trades the model's signals with a one-day lag, costs and slippage, against buy and hold over the same period. The assumptions are on screen."
7. "Walk-forward validation repeats the test over several chronological folds with no future data."
8. "That is the final dashboard: one window, honest evaluation."

## Recording checklist (manual re-recording)

- [ ] Window about 1500 x 980; Tech Growth dataset; start from a fresh launch.
- [ ] Do not open any other window; no popups should appear.
- [ ] Follow the timeline above; keep total length under 2:00.
- [ ] Capture the whole window; export at 1080p or the native window size.
