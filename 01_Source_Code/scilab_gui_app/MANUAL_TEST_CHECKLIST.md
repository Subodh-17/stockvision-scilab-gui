# Manual GUI test checklist

Everything in `model_engine.sce` (the actual math, including the new
Exponential Smoothing model) is covered by the 171-assertion headless test
suite in `test_model_engine.sce`, which runs with no display and is re-run
on every change. It cannot, by its nature, click a button -- GUI callback
wiring needs a real window. This checklist is the fast, systematic way to
cover that remaining piece: about 6 minutes, covering all six main actions
in one pass through the app.

Run `scilab -f gui_app.sce`, then work through the boxes in order (each
step assumes the previous ones were completed):

## 1. Startup
- [ ] Window opens at roughly 1050x900, nothing overlapping, all labels
      readable
- [ ] "Tech Growth Stock (synthetic demo data)" is pre-selected (data is
      loaded automatically, but no chart yet -- that only appears once you
      click Run Analysis, in its own separate window, see below)
- [ ] Status bar shows something like "Loaded 300 rows..."
- [ ] The Model dropdown shows "Linear Regression" selected, with "AR
      Time-Series (autoregressive)" and "Exponential Smoothing (Holt)" as
      the other two options
- [ ] The right-hand panel says "Charts open in separate windows..."

## 2. Run Analysis
- [ ] Click **Run Analysis** with the defaults (Linear Regression, 80/20
      split). A **separate chart window** opens (actual vs. predicted,
      with gridlines), and the Results panel in the MAIN window fills in:
      Dataset, Model, RMSE, MAE, MAPE, R², **Prediction Accuracy %**,
      current/predicted price, the "rough band... NOT a true prediction
      interval" line, and a SIGNAL
- [ ] A colour-coded **BUY / SELL / HOLD** indicator appears next to the
      "Results" label (green for BUY, red for SELL, grey for HOLD) --
      matches the SIGNAL text in the Results panel below it
- [ ] **Critically: the main window (buttons, dropdowns, sliders) is still
      fully visible and clickable** -- nothing should have closed,
      cleared, or become unresponsive
- [ ] Switch the Model dropdown to **AR Time-Series**, click Run Analysis
      again -- numbers change, the SAME chart window updates (doesn't open
      a new one each time), main window still fine
- [ ] Switch the Model dropdown to **Exponential Smoothing (Holt)**, click
      Run Analysis again -- numbers change again (typically smoother,
      lower-variance predictions than LR/AR since this model only tracks a
      running level/trend, no raw-price lookback), signal indicator updates,
      chart title mentions "Exp. Smoothing" and the alpha/beta used
- [ ] Drag the **Train/Test Split** slider -- label updates live, status
      bar says "Split changed -- click Run Analysis to refit", and Results
      panel resets to the placeholder (confirms the stale-model
      invalidation works)
- [ ] Click Run Analysis again to refit at the new split
- [ ] Toggle **Show 20-day moving average** -- chart redraws immediately
      with a third line, *no* need to click Run Analysis again
- [ ] Change the **AR lookback**, **Buy/Sell thresholds**, or **Txn
      cost/Slippage** edit boxes to something odd (e.g. letters instead of
      a number) and click Run Analysis -- it should fall back to the
      previous default and visibly rewrite the box, not error out
- [ ] Close the Run Analysis chart window (its own X button, not the main
      window's) -- **the main window stays open and fully usable**. Click
      Run Analysis again -- a fresh chart window opens without issue

## 3. Compare
- [ ] Click **Compare** -- a **new chart window** opens with two bar
      charts side by side: single-split RMSE and 3-fold walk-forward mean
      RMSE, one bar each for LR / AR / Exponential Smoothing
- [ ] The Results panel in the MAIN window (not a popup) now shows the
      same LR/AR/ES metrics as text -- RMSE/MAE/MAPE/R² plus the
      walk-forward mean for each of the three models
- [ ] **No popup/dialog appears** -- Compare no longer interrupts the
      session; both the chart window and the main window are usable
      immediately

## 4. Run Backtest
- [ ] Click **Run Backtest** -- a *second* chart window opens (strategy vs.
      buy & hold, with gridlines), and the Results panel in the MAIN
      window (not a popup) shows trades made, strategy/buy&hold final
      value and return %, max drawdown, volatility, Sharpe ratio, win rate
- [ ] **No popup/dialog appears** for a successful backtest -- results
      land directly in the Results panel
- [ ] Set **Txn cost** to something nonzero (e.g. `1`), click Run Backtest
      again -- the strategy's final value should be visibly lower than the
      zero-cost run
- [ ] Close the Run Analysis chart window (the X on that window, not the
      main one) -- **the main app window and the backtest window both stay
      open**. Same test the other way: close the backtest chart window,
      main window and analysis chart are unaffected. Closing a chart
      window must never close the application.

## 5. Export
- [ ] Click **Export**, type a filename ending in `.csv`, save -- open it
      in a text editor or spreadsheet: should have a `Metric,Value` block
      (including `Dataset`, and every number the Results panel showed)
      followed by an `Index,Actual,Predicted` table, and (since you ran a
      backtest above) a set of `Backtest_*` rows
- [ ] Click Export again, save as `.pdf` this time -- opens as a real PDF
      showing the current chart
- [ ] Click Export once more, save as `.txt` -- plain-text version of the
      Results panel + last backtest summary
- [ ] Repeat one Export (any format) with **Exponential Smoothing**
      selected as the model -- confirms export isn't hardcoded to LR/AR

## 6. Reset
- [ ] Click **Reset** -- the three chart windows (if open) clear, Results
      panel goes back to the placeholder, the colour-coded signal
      indicator clears, threshold/lookback/cost boxes go back to their
      defaults (0.5 / -0.5 / 10 / 0 / 0)
- [ ] **The main window itself is untouched** -- still fully visible,
      every button/dropdown/slider still there and clickable, not reset to
      blank or closed
- [ ] Run a full Run Analysis again right after Reset, without restarting
      Scilab -- confirms one session supports multiple analyses back to
      back

## 7. Load Custom CSV
- [ ] File > Load Custom CSV..., pick any bundled file from `sample_data/`
      (or your own, matching the `Date,Open,High,Low,Close,Volume` format)
      -- loads, dropdown gains/updates a "Custom: ..." entry, model
      invalidated (same as changing the split)
- [ ] Try loading an obviously bad file (e.g. rename a `.txt` file to
      `.csv`, or a spreadsheet export with the wrong columns) -- should
      show a friendly error popup, not a raw Scilab console error

## 8. Full cycle, repeated -- without restarting Scilab
This is the single most important check given this app's history: **one
Scilab session must support the entire workflow multiple times over**,
with the main window surviving every step.
- [ ] Pick a dataset -> Run Analysis (LR) -> Run Backtest -> Compare ->
      Export (any format) -> switch to AR -> Run Analysis again -> Run
      Backtest again -> switch to Exponential Smoothing -> Run Analysis a
      third time -> close all three chart windows -> pick a *different*
      dataset -> Run Analysis a fourth time
- [ ] At every step above, the main window (buttons, dropdowns, sliders,
      Results panel) stayed open, responsive, and showed the right data --
      never needed a restart, never went blank, never closed unexpectedly

## If something breaks
Note the **exact** error text (or screenshot the popup) and which step it
happened on -- that's a real bug in the GUI wiring, not a documentation gap,
and the fastest way to get it fixed.
