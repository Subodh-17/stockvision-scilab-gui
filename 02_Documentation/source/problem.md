---
title: "StockVision - Problem Statement"
subtitle: "Problem Statement (V2) | Scilab GUIVerse Hackathon"
---

# 1. The problem

I saw a gap between introductory Scilab examples and an interactive application that lets a learner explore a realistic predictive workflow. Stock-price prediction is often presented as a black box: data goes in and a number comes out, while the user has little chance to see how modelling choices, training history, validation design and trading assumptions change the answer - or whether the model beats a trivial guess at all.

Stock-market modelling naturally combines data visualization, forecasting, comparison, validation and decision-oriented analysis in one GUI workflow, which fits the hackathon's focus on original, interactive Scilab applications.

# 2. The gap I wanted to fill

I wanted a lightweight Scilab application in which a user can answer questions such as:

- How does a feature-based Linear Regression compare with an autoregressive model and with Holt exponential smoothing on the **same data and the same test window**?
- Does any of them beat a **naive "tomorrow equals today" baseline**? If not, the application should say so.
- How do results change when the train/test split, the AR lookback or the number of validation folds changes?
- Do the models hold up under **walk-forward validation** rather than a single split?
- What happens to a model-guided signal once a one-day execution lag, transaction costs and slippage are applied, and how does it compare with **buy and hold** over the same period?
- Is the data itself trustworthy (missing values, duplicates, ordering, impossible bars)?

Normally this requires writing code, running separate experiments and comparing outputs by hand. I wanted a single interactive workflow.

# 3. What I built

StockVision is a Scilab GUI organised as **one integrated dashboard**: controls on the left; the price/prediction chart, model-comparison chart and equity curve embedded in the same window; and panels for data quality, model results, metric comparison with ranking, walk-forward folds, backtest summary and backtest assumptions. Nothing opens in a separate window.

The models are Linear Regression (12 engineered features), an AR time-series model, Holt exponential smoothing and a naive baseline. All are evaluated with RMSE, MAE, MAPE, R^2 and directional accuracy; the ranking is computed from the actual results. Model Info explains each model's purpose, assumptions and limitations in plain language.

# 4. Intended users and use cases

Students and learners of regression, time-series modelling, smoothing methods, data visualization and basic financial analysis. A user can compare modelling approaches, see why a baseline matters, test how parameter choices affect results, understand evaluation metrics, and see how a simple historical strategy behaves under explicit assumptions.

# 5. Why this approach

I chose depth of evaluation over breadth of features. Every control changes a real modelling, validation or backtesting input; every displayed number is computed from the data; and the application deliberately reports unflattering outcomes. On the bundled synthetic datasets, for example, none of the three models achieves a lower test RMSE than the naive baseline - which is an honest and educational result rather than a defect to hide.

# 6. Scope, limitations and responsible use

- The bundled datasets are **synthetic demonstration data**; there is no live market connection.
- StockVision is an educational and analytical tool. It is **not investment advice** and does not claim to predict markets or generate profit. Past or simulated performance does not indicate future results.
- Backtests cover short windows, are long/cash only, and ignore bid/ask spread, partial fills, intraday movement and market impact; annualized figures from short windows are extrapolations.
- Models are simple linear/smoothing methods with fixed or user-chosen parameters; there is no deep learning and no external AI service.
- Metrics are noisy on small samples and no statistical significance testing is performed.

# 7. Expected outcome

My objective is not to claim that a model can reliably predict financial markets. It is to make the modelling process understandable and testable: compare approaches against a baseline, question parameter choices, validate forward in time, and see how a simple strategy behaves under explicit assumptions.

In one sentence: I built StockVision to turn stock forecasting from a single black-box number into an interactive, honest Scilab workflow for comparison, validation, visualization and practical evaluation.
