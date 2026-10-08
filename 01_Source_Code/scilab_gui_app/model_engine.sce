// ============================================================================
// model_engine.sce -- StockVision modelling engine (no GUI code).
//
// Pure functions: plain data in, plain data out, so everything here runs
// headless (see test_model_engine.sce). gui_app.sce only calls these.
// Load with: exec("model_engine.sce", -1);
//
// Sections: 1 CSV parsing/validation, 2 shared metrics, 3 models (LR, AR,
// Holt ES, naive), 4 common-window runner + comparison + ranking,
// 5 walk-forward, 6 signals + backtest, 7 text reports, 8 export.
//
// Evaluation protocol (all models):
//   * chronological split on calendar rows: train targets <= split_cal,
//     test targets = split_cal+1 .. n (identical window for every model);
//   * scaling/fit parameters come from training rows only;
//   * forecast for day t uses data up to day t-1 only.
// ============================================================================


// ---------------------------------------------------------------------------
// 1. CSV parsing and validation
// ---------------------------------------------------------------------------
function ok = is_valid_number_string(s)
    // Optional sign, digits, at most one '.'; no exponents or separators.
    // Digits are compared via ascii() codes: Scilab has no <,> on strings.
    s = stripblanks(s);
    ok = %f;
    if s == "" then return; end
    n = length(s);
    i = 1;
    if part(s, 1) == "+" | part(s, 1) == "-" then i = 2; end
    if i > n then return; end
    has_digit = %f; has_dot = %f;
    ZERO_CODE = ascii("0"); NINE_CODE = ascii("9");
    while i <= n
        c = part(s, i);
        c_code = ascii(c);
        if c_code >= ZERO_CODE & c_code <= NINE_CODE then
            has_digit = %t;
        elseif c == "." & ~has_dot then
            has_dot = %t;
        else
            return
        end
        i = i + 1;
    end
    ok = has_digit;
endfunction


function ok = is_valid_calendar_date(y, m, d)
    // Real calendar check, leap years included.
    days_in_month = [31 28 31 30 31 30 31 31 30 31 30 31];
    ok = %f;
    if m < 1 | m > 12 then return; end
    dim = days_in_month(m);
    if m == 2 & modulo(y, 4) == 0 & (modulo(y, 100) <> 0 | modulo(y, 400) == 0) then
        dim = 29;
    end
    ok = (d >= 1) & (d <= dim);
endfunction


function [y, m, d, ok] = parse_iso_date(s)
    // Strict YYYY-MM-DD; day-level ordering only, no time zones.
    y = 0; m = 0; d = 0; ok = %f;
    s = stripblanks(s);
    if length(s) <> 10 then return; end
    if part(s, 5) <> "-" | part(s, 8) <> "-" then return; end
    y_str = part(s, 1:4); m_str = part(s, 6:7); d_str = part(s, 9:10);
    if ~is_valid_number_string(y_str) | ~is_valid_number_string(m_str) | ~is_valid_number_string(d_str) then
        return
    end
    y = strtod(y_str); m = strtod(m_str); d = strtod(d_str);
    if ~is_valid_calendar_date(y, m, d) then
        y = 0; m = 0; d = 0; return
    end
    ok = %t;
endfunction


function fields = split_csv_line(line)
    // Splits on commas into a 1xN string row. Two passes (count, then fill)
    // so the result is preallocated as a string matrix.
    n = length(line);
    n_commas = 0;
    for pos = 1:n
        if part(line, pos) == "," then
            n_commas = n_commas + 1;
        end
    end
    fields = repmat("", 1, n_commas + 1);
    field_idx = 1;
    field_start = 1;
    for pos = 1:n
        if part(line, pos) == "," then
            fields(field_idx) = part(line, field_start:pos-1);
            field_idx = field_idx + 1;
            field_start = pos + 1;
        end
    end
    fields(field_idx) = part(line, field_start:n);
endfunction


function data = load_dataset_impl(csv_path)
    // Loads Date,Open,High,Low,Close,Volume. Returns a struct: dates, open,
    // high, low, close, volume, n, warnings, quality.
    // Fatal problems (header, no/too few usable rows, duplicate dates) call
    // error(); fixable ones (bad rows, unsorted file) are cleaned and
    // reported in data.warnings. The file is read with mgetl + manual split
    // (not csvRead) so every field stays a plain string until validated.
    MIN_ROWS_LOAD = 30;

    if ~isfile(csv_path) then
        error("CSV error: file not found -- [" + csv_path + "].");
    end

    all_lines = mgetl(csv_path);
    if size(all_lines, 1) == 0 then
        error("CSV error: [" + csv_path + "] is empty.");
    end

    // Strip a trailing CR left by Windows line endings.
    CR = ascii(13);
    for i = 1:size(all_lines, 1)
        li = all_lines(i);
        if length(li) > 0 then
            if part(li, length(li)) == CR then
                all_lines(i) = part(li, 1:length(li)-1);
            end
        end
    end

    // Drop trailing blank lines (guarded so all_lines($) is never read when empty).
    trimming = %t;
    while trimming
        n_ll = size(all_lines, 1);
        if n_ll == 0 then
            trimming = %f;
        elseif stripblanks(all_lines(n_ll)) == "" then
            all_lines = all_lines(1:n_ll-1);
        else
            trimming = %f;
        end
    end

    if size(all_lines, 1) < 2 then
        error("CSV error: [" + csv_path + "] has no data rows (only a header, or is empty).");
    end

    expected = ["Date", "Open", "High", "Low", "Close", "Volume"];
    header_fields = split_csv_line(all_lines(1));
    if size(header_fields, 2) <> 6 then
        error("CSV error: expected exactly 6 columns (Date,Open,High,Low,Close,Volume), " + ..
              "found " + string(size(header_fields, 2)) + " in [" + csv_path + "].");
    end
    for j = 1:6
        if convstr(stripblanks(header_fields(j)), "l") <> convstr(expected(j), "l") then
            error("CSV error: column " + string(j) + " is labeled [" + header_fields(j) + ..
                  "], expected [" + expected(j) + "]. Columns must appear in the order " + ..
                  "Date,Open,High,Low,Close,Volume.");
        end
    end

    n_raw = size(all_lines, 1) - 1;
    warnings = repmat("", 0, 1);
    n_bad_numeric = 0; n_bad_date = 0; n_bad_ohlc = 0; n_bad_volume = 0; n_blank = 0;
    n_bad_fieldcount = 0;

    // Preallocated Nx1 columns, filled by counter k and truncated below.
    dates_kept = repmat("", n_raw, 1);
    open_kept = zeros(n_raw, 1); high_kept = zeros(n_raw, 1); low_kept = zeros(n_raw, 1);
    close_kept = zeros(n_raw, 1); volume_kept = zeros(n_raw, 1); serial_kept = zeros(n_raw, 1);
    k = 0;

    EPS = 1e-6;
    for i = 1:n_raw
        line_i = all_lines(i + 1);
        if stripblanks(line_i) == "" then
            n_blank = n_blank + 1;
            continue
        end

        row = split_csv_line(line_i);
        if size(row, 2) <> 6 then
            n_bad_fieldcount = n_bad_fieldcount + 1;
            continue
        end
        if and(stripblanks(row) == "") then
            n_blank = n_blank + 1;
            continue
        end

        [y, m, d, date_ok] = parse_iso_date(row(1));
        if ~date_ok then
            n_bad_date = n_bad_date + 1;
            continue
        end

        nums_ok = is_valid_number_string(row(2)) & is_valid_number_string(row(3)) & ..
                  is_valid_number_string(row(4)) & is_valid_number_string(row(5)) & ..
                  is_valid_number_string(row(6));
        if ~nums_ok then
            n_bad_numeric = n_bad_numeric + 1;
            continue
        end

        o = strtod(row(2)); h = strtod(row(3)); l = strtod(row(4));
        c = strtod(row(5)); v = strtod(row(6));

        if v < 0 then
            n_bad_volume = n_bad_volume + 1;
            continue
        end

        // Daily bar sanity: Low <= {Open, Close} <= High, all prices > 0.
        if l <= 0 | h <= 0 | o <= 0 | c <= 0 | h < l - EPS | o < l - EPS | ..
           o > h + EPS | c < l - EPS | c > h + EPS then
            n_bad_ohlc = n_bad_ohlc + 1;
            continue
        end

        k = k + 1;
        dates_kept(k) = row(1);
        open_kept(k) = o; high_kept(k) = h; low_kept(k) = l;
        close_kept(k) = c; volume_kept(k) = v;
        serial_kept(k) = y*372 + m*31 + d;   // monotonic ordering key only
    end

    n_kept = k;
    if n_kept == 0 then
        error("CSV error: no usable rows survived validation in [" + csv_path + "] -- " + ..
              "check the file has valid YYYY-MM-DD dates, numeric OHLCV values, " + ..
              "and High >= Low.");
    end

    dates_kept = dates_kept(1:n_kept); open_kept = open_kept(1:n_kept);
    high_kept = high_kept(1:n_kept); low_kept = low_kept(1:n_kept);
    close_kept = close_kept(1:n_kept); volume_kept = volume_kept(1:n_kept);
    serial_kept = serial_kept(1:n_kept);

    n_dropped = n_raw - n_kept;
    if n_dropped > 0 then
        detail = "";
        if n_blank > 0 then detail = detail + string(n_blank) + " blank, "; end
        if n_bad_fieldcount > 0 then detail = detail + string(n_bad_fieldcount) + " wrong field count, "; end
        if n_bad_date > 0 then detail = detail + string(n_bad_date) + " bad/malformed date, "; end
        if n_bad_numeric > 0 then detail = detail + string(n_bad_numeric) + " non-numeric OHLCV, "; end
        if n_bad_volume > 0 then detail = detail + string(n_bad_volume) + " negative volume, "; end
        if n_bad_ohlc > 0 then detail = detail + string(n_bad_ohlc) + " impossible OHLC (e.g. Low>High), "; end
        detail = part(detail, 1:length(detail)-2);
        warnings = [warnings; "Dropped " + string(n_dropped) + " of " + string(n_raw) + ..
                    " rows (" + detail + ")."];
    end

    // Duplicate dates cannot be repaired safely: fatal.
    [sorted_serial, sort_idx] = gsort(serial_kept, "g", "i");
    for i = 2:n_kept
        if sorted_serial(i) == sorted_serial(i-1) then
            error("CSV error: duplicate date [" + dates_kept(sort_idx(i)) + "] found in [" + ..
                  csv_path + "]. Every row must have a unique date.");
        end
    end

    // Unsorted files are sorted ascending (e.g. newest-first exports).
    was_sorted = %t;
    for i = 1:n_kept
        if sort_idx(i) <> i then was_sorted = %f; end
    end
    if ~was_sorted then
        dates_kept = dates_kept(sort_idx); open_kept = open_kept(sort_idx);
        high_kept = high_kept(sort_idx); low_kept = low_kept(sort_idx);
        close_kept = close_kept(sort_idx); volume_kept = volume_kept(sort_idx);
        warnings = [warnings; "Rows were not in ascending chronological order -- " + ..
                    "automatically sorted by date."];
    end

    if n_kept < MIN_ROWS_LOAD then
        error("CSV error: only " + string(n_kept) + " usable rows in [" + csv_path + ..
              "] -- need at least " + string(MIN_ROWS_LOAD) + " for the models to fit " + ..
              "reliably. Load a longer dataset.");
    end

    data = struct();
    data.dates = dates_kept; data.open = open_kept; data.high = high_kept;
    data.low = low_kept; data.close = close_kept; data.volume = volume_kept;
    data.n = n_kept;
    data.warnings = warnings;

    // Counters behind the GUI's Data Quality panel (raw-file view).
    q = struct();
    q.raw_rows = n_raw;
    q.rows = n_kept;
    q.dropped = n_dropped;
    q.missing = n_blank + n_bad_fieldcount + n_bad_numeric;
    q.bad_dates = n_bad_date;
    q.invalid_ohlc = n_bad_ohlc + n_bad_volume;
    q.duplicates = 0;                 // duplicates are fatal above
    q.was_chronological = was_sorted;
    q.date_first = dates_kept(1);
    q.date_last = dates_kept($);
    data.quality = q;
endfunction


function data = load_dataset(csv_path)
    // Wraps load_dataset_impl so unexpected internal errors still name the
    // file; its own validation errors pass through with that context added.
    try
        data = load_dataset_impl(csv_path);
    catch
        underlying = lasterror();
        error("CSV error: failed to load [" + csv_path + "] -- " + underlying + ..
              " -- if this message does not look like one of the load_dataset_impl " + ..
              "validation errors, it is an unexpected internal error; please " + ..
              "report the exact text above.");
    end
endfunction


function d = slice_data(data, k)
    // First k rows only. Used by walk-forward so fold models cannot see
    // anything after the fold's end (structural no-future guarantee).
    d = struct();
    d.dates = data.dates(1:k); d.open = data.open(1:k); d.high = data.high(1:k);
    d.low = data.low(1:k); d.close = data.close(1:k); d.volume = data.volume(1:k);
    d.n = k; d.warnings = data.warnings;
    if isfield(data, "quality") then d.quality = data.quality; end
endfunction


function dq = data_quality_summary(data, split_ratio)
    // Dataset-level quality numbers; train/test rows use the common split
    // (split_cal = round(n*ratio) calendar rows before the test window).
    q = data.quality;
    dq = struct();
    dq.rows = data.n;
    dq.date_first = q.date_first; dq.date_last = q.date_last;
    dq.missing_dropped = q.missing;
    dq.missing_remaining = sum(isnan(data.close)) + sum(isnan(data.open)) + ..
                           sum(isnan(data.high)) + sum(isnan(data.low)) + sum(isnan(data.volume));
    dq.duplicates = q.duplicates;
    dq.chronological = q.was_chronological;   // source file order (loader always sorts)
    dq.bad_dates = q.bad_dates;
    dq.invalid_ohlc = q.invalid_ohlc;
    dq.dropped = q.dropped; dq.raw_rows = q.raw_rows;
    dq.split_ratio = split_ratio;
    dq.train_rows = round(data.n * split_ratio);
    dq.test_rows = data.n - dq.train_rows;
    if dq.train_rows >= 1 & dq.train_rows <= data.n then
        dq.train_last = data.dates(dq.train_rows);
    else
        dq.train_last = "n/a";
    end
    if dq.test_rows >= 1 then
        dq.test_first = data.dates(dq.train_rows + 1);
    else
        dq.test_first = "n/a";
    end
endfunction


// ---------------------------------------------------------------------------
// 2. Shared metrics
// ---------------------------------------------------------------------------
function m = compute_metrics(y_true, y_pred, y_prev)
    // RMSE, MAE, MAPE, R^2, accuracy and directional accuracy for one test
    // window. y_prev (the close before each target) is optional; without it
    // dir_acc is NaN.
    // Directional accuracy: share of days whose predicted move sign matches
    // the actual move sign; days with zero actual move are excluded, and a
    // forecast that never moves from y_prev (e.g. naive) has no direction
    // skill to score, so it returns NaN.
    if argn(2) < 3 then y_prev = []; end
    y_true = y_true(:); y_pred = y_pred(:);
    residuals = y_true - y_pred;

    m = struct();
    m.rmse = sqrt(mean(residuals.^2));
    m.mae = mean(abs(residuals));

    mape_mask = abs(y_true) > 1e-8;      // zero actual price: % error undefined
    if or(mape_mask) then
        m.mape = mean(abs(residuals(mape_mask) ./ y_true(mape_mask))) * 100;
    else
        m.mape = %nan;
    end

    ss_res = sum(residuals.^2);
    ss_tot = sum((y_true - mean(y_true)).^2);
    if ss_tot > 1e-12 then
        m.r2 = 1 - ss_res / ss_tot;
    elseif ss_res < 1e-12 then
        m.r2 = 1;                         // constant target, matched exactly
    else
        m.r2 = %nan;                      // constant target: R^2 undefined
    end

    if isnan(m.mape) then
        m.accuracy_pct = %nan;
    else
        m.accuracy_pct = max(0, 100 - m.mape);
    end

    m.dir_acc = %nan;
    if size(y_prev, "*") == size(y_true, "*") & size(y_true, "*") > 0 then
        y_prev = y_prev(:);
        act_move = y_true - y_prev;
        prd_move = y_pred - y_prev;
        scored = act_move <> 0;
        if or(scored) & ~and(prd_move == 0) then
            m.dir_acc = sum(sign(prd_move(scored)) == sign(act_move(scored))) / sum(scored) * 100;
        end
    end
endfunction


// ---------------------------------------------------------------------------
// 3a. Linear Regression (12 engineered features)
// ---------------------------------------------------------------------------
function feat = build_lr_features(data)
    // Features at row i use data up to day i only; target is close(i+1).
    // feat.row_idx(j) is the calendar row of feature row j (its target is
    // calendar row row_idx+1). feat.latest_raw is today's own feature row,
    // used for the next-day forecast.
    n = data.n;
    close = data.close;

    if n < 15 then
        error("build_lr_features: need at least 15 rows to build lag/MA10 features " + ..
              "(got " + string(n) + ").");
    end

    lag1 = [%nan; close(1:$-1)];
    lag2 = [%nan; %nan; close(1:$-2)];
    lag3 = [%nan; %nan; %nan; close(1:$-3)];

    ma5 = zeros(n, 1); ma10 = zeros(n, 1); vol5 = zeros(n, 1);
    for i = 5:n
        ma5(i) = mean(close(i-4:i));
        vol5(i) = stdev(close(i-4:i));
    end
    for i = 10:n
        ma10(i) = mean(close(i-9:i));
    end
    ma5(1:4) = %nan; vol5(1:4) = %nan; ma10(1:9) = %nan;

    return_1d = [%nan; (close(2:$) - close(1:$-1)) ./ close(1:$-1)];
    target = [close(2:$); %nan];   // row i's target is TOMORROW's close

    X_raw_all = [data.open, data.high, data.low, close, data.volume, ..
                 return_1d, ma5, ma10, vol5, lag1, lag2, lag3];
    valid_rows = and(~isnan(X_raw_all), "c") & ~isnan(target);

    feat = struct();
    feat.X_raw = X_raw_all(valid_rows, :);
    feat.y = target(valid_rows);
    feat.row_idx = matrix(find(valid_rows), -1, 1);
    feat.n_valid = size(feat.X_raw, 1);
    feat.feature_names = ["Open","High","Low","Close","Volume", ..
                           "Return_1d","MA_5","MA_10","Volatility_5","Lag_1","Lag_2","Lag_3"];

    // Today's row has no target (excluded above) but its features are known
    // and are exactly what the next-day forecast needs.
    if or(isnan(X_raw_all(n, :))) then
        error("build_lr_features: the most recent row is missing feature values " + ..
              "(need at least 15 rows before the newest one).");
    end
    feat.latest_raw = X_raw_all(n, :);

    if feat.n_valid < 20 then
        error("build_lr_features: only " + string(feat.n_valid) + " valid training rows " + ..
              "survive after dropping warm-up/NaN rows -- need at least 20. " + ..
              "Load a longer dataset.");
    end
endfunction


function model = fit_lr_at(feat, split_idx)
    // Least squares on standardized features; the first split_idx valid rows
    // train, the rest test. mu/sigma come from the training rows only.
    n_valid = feat.n_valid;
    if split_idx < 1 | split_idx >= n_valid then
        error("fit_linear_regression: train/test split leaves an empty side (" + ..
              string(split_idx) + " train / " + string(n_valid - split_idx) + ..
              " test rows) -- adjust the split slider.");
    end

    X_train_raw = feat.X_raw(1:split_idx, :);
    y_train = feat.y(1:split_idx);
    X_test_raw = feat.X_raw(split_idx+1:$, :);
    y_test = feat.y(split_idx+1:$);

    mu = mean(X_train_raw, "r");
    sigma = stdev(X_train_raw, "r");
    sigma(sigma == 0) = 1;

    n_train = split_idx; n_test = n_valid - split_idx;
    X_train = (X_train_raw - repmat(mu, n_train, 1)) ./ repmat(sigma, n_train, 1);
    X_test  = (X_test_raw  - repmat(mu, n_test, 1))  ./ repmat(sigma, n_test, 1);

    X_train_aug = [ones(n_train, 1), X_train];
    beta = X_train_aug \ y_train;   // backslash: more stable than normal equations

    model = struct();
    model.beta = beta; model.mu = mu; model.sigma = sigma;
    model.X_test = X_test; model.y_test = y_test;
    model.y_prev_test = X_test_raw(:, 4);          // Close column = previous close
    model.row_idx_test = feat.row_idx(split_idx+1:$);
    model.split_idx = split_idx;
    model.latest_raw = feat.latest_raw;

    train_pred = X_train_aug * beta;
    model.train_residual_std = stdev(y_train - train_pred);
endfunction


function model = fit_linear_regression(feat, split_ratio)
    model = fit_lr_at(feat, round(feat.n_valid * split_ratio));
endfunction


function ev = evaluate_model(model)
    // Test-window metrics for an LR (or any intercept+X_test) model.
    X_test_aug = [ones(size(model.X_test,1),1), model.X_test];
    y_pred = X_test_aug * model.beta;
    prev = [];
    if isfield(model, "y_prev_test") then prev = model.y_prev_test; end
    ev = compute_metrics(model.y_test, y_pred, prev);
    ev.y_pred = y_pred;
endfunction


function [next_price, ci_low, ci_high] = predict_next_lr(model)
    // Tomorrow's close from today's own feature row, plus a rough +/-95%
    // band from the training residual spread (normal approximation, not a
    // true prediction interval).
    latest_scaled = (model.latest_raw - model.mu) ./ model.sigma;
    latest_aug = [1, latest_scaled];
    next_price = latest_aug * model.beta;

    margin = 1.96 * model.train_residual_std;
    ci_low = next_price - margin;
    ci_high = next_price + margin;
endfunction


// ---------------------------------------------------------------------------
// 3b. AR(p): linear autoregression on the last p closes, fit by least
// squares. NOT an LSTM and not a neural network.
// ---------------------------------------------------------------------------
function model = fit_ar_at(data, p, split_idx)
    // Sample i uses close(i..i+p-1) to predict close(i+p). The first
    // split_idx samples train; the price scaling range uses them only.
    close = data.close;
    n = data.n;

    if p < 2 then
        error("fit_ar_model: lookback (p) must be at least 2 (got " + string(p) + ").");
    end
    n_samples = n - p;
    if n_samples < 20 then
        error("fit_ar_model: only " + string(n_samples) + " samples available with a " + ..
              string(p) + "-day lookback on " + string(n) + " rows -- need at least 20. " + ..
              "Use a shorter lookback or a longer dataset.");
    end
    if split_idx < 1 | split_idx >= n_samples then
        error("fit_ar_model: train/test split leaves an empty side -- adjust the split slider.");
    end

    X_raw = zeros(n_samples, p);
    y = zeros(n_samples, 1);
    for i = 1:n_samples
        X_raw(i, :) = close(i:i+p-1)';
        y(i) = close(i+p);
    end

    X_train_raw = X_raw(1:split_idx, :); y_train_raw = y(1:split_idx);
    X_test_raw  = X_raw(split_idx+1:$, :); y_test_raw  = y(split_idx+1:$);

    price_min = min([X_train_raw(:); y_train_raw]);
    price_max = max([X_train_raw(:); y_train_raw]);
    price_range = price_max - price_min;
    if price_range < 1e-8 then
        price_range = 1;   // all training prices identical
    end

    X_train = (X_train_raw - price_min) / price_range;
    y_train = (y_train_raw - price_min) / price_range;
    X_test  = (X_test_raw  - price_min) / price_range;
    y_test  = (y_test_raw  - price_min) / price_range;

    X_train_aug = [ones(size(X_train,1),1), X_train];
    beta = X_train_aug \ y_train;

    model = struct();
    model.beta = beta; model.p = p; model.split_idx = split_idx;
    model.price_min = price_min; model.price_max = price_min + price_range;
    model.X_test = X_test; model.y_test = y_test;
    model.y_prev_test = X_test_raw(:, p);          // last close in each window
    model.y_train_real = y_train_raw;

    latest_window = (close($-p+1:$)' - price_min) / price_range;
    model.X_scaled_last_row = latest_window;

    train_pred_scaled = X_train_aug * beta;
    resid_scaled = y_train - train_pred_scaled;
    model.train_residual_std = stdev(resid_scaled) * price_range;   // price units
endfunction


function model = fit_ar_model(data, p, split_ratio)
    n_samples = max(data.n - p, 0);
    model = fit_ar_at(data, p, round(n_samples * split_ratio));
endfunction


function ev = evaluate_ar_model(model)
    // Works in scaled space; metrics are computed in real price units.
    X_test_aug = [ones(size(model.X_test,1),1), model.X_test];
    y_pred_scaled = X_test_aug * model.beta;

    rng_p = model.price_max - model.price_min;
    y_test_real = model.y_test * rng_p + model.price_min;
    y_pred_real = y_pred_scaled * rng_p + model.price_min;

    ev = compute_metrics(y_test_real, y_pred_real, model.y_prev_test);
    ev.y_pred = y_pred_real;
    ev.y_test_real = y_test_real;
endfunction


function [next_price, ci_low, ci_high] = predict_next_ar(model)
    latest_aug = [1, model.X_scaled_last_row];
    next_price_scaled = latest_aug * model.beta;
    price_range = model.price_max - model.price_min;
    next_price = next_price_scaled * price_range + model.price_min;

    margin = 1.96 * model.train_residual_std;
    ci_low = next_price - margin;
    ci_high = next_price + margin;
endfunction


// ---------------------------------------------------------------------------
// 3c. Exponential smoothing (Holt's linear trend). alpha (level) and beta
// (trend) are fixed inputs, not fitted, so there is no parameter leakage.
// The state is ONE continuous recursion over the series: each forecast
// uses only earlier prices, and restarting cold at the train/test boundary
// would throw away the sequential memory that defines the model.
// ---------------------------------------------------------------------------
function [L, T, fcst] = holt_recursion(close, alpha, beta)
    // L, T: running level/trend (L(1), T(1) are seeds). fcst(1) = NaN;
    // fcst(t) = L(t-1) + T(t-1), the forecast of close(t) made BEFORE close(t)
    // updates the state.
    n = size(close, 1);
    L = zeros(n, 1); T = zeros(n, 1); fcst = zeros(n, 1) * %nan;
    L(1) = close(1);
    T(1) = close(2) - close(1);
    for t = 2:n
        fcst(t) = L(t-1) + T(t-1);
        L(t) = alpha * close(t) + (1 - alpha) * (L(t-1) + T(t-1));
        T(t) = beta * (L(t) - L(t-1)) + (1 - beta) * T(t-1);
    end
endfunction


function model = fit_es_at(data, split_idx, alpha, beta)
    if alpha <= 0 | alpha > 1 | beta < 0 | beta > 1 then
        error("fit_exponential_smoothing: alpha must be in (0,1] and beta in [0,1] " + ..
              "(got alpha=" + string(alpha) + ", beta=" + string(beta) + ").");
    end
    close = data.close;
    n = data.n;
    if n < 10 then
        error("fit_exponential_smoothing: need at least 10 rows (got " + string(n) + ").");
    end
    if split_idx < 2 | split_idx >= n then
        error("fit_exponential_smoothing: train/test split leaves an empty side -- " + ..
              "adjust the split slider.");
    end

    [L, T, fcst] = holt_recursion(close, alpha, beta);

    train_pred = fcst(2:split_idx);
    train_actual = close(2:split_idx);

    model = struct();
    model.alpha = alpha; model.beta = beta;
    model.split_idx = split_idx; model.n = n;
    model.y_test = close(split_idx+1:n);
    model.y_pred = fcst(split_idx+1:n);
    model.y_prev_test = close(split_idx:n-1);
    model.train_residual_std = stdev(train_actual - train_pred);
    model.final_level = L(n); model.final_trend = T(n);
endfunction


function model = fit_exponential_smoothing(data, split_ratio, alpha, beta)
    model = fit_es_at(data, round(data.n * split_ratio), alpha, beta);
endfunction


function ev = evaluate_es_model(model)
    ev = compute_metrics(model.y_test, model.y_pred, model.y_prev_test);
    ev.y_pred = model.y_pred;
endfunction


function [next_price, ci_low, ci_high] = predict_next_es(model)
    // Level + trend are already up to date through today.
    next_price = model.final_level + model.final_trend;
    margin = 1.96 * model.train_residual_std;
    ci_low = next_price - margin;
    ci_high = next_price + margin;
endfunction


// ---------------------------------------------------------------------------
// 4. Common-window runner, comparison and ranking
// ---------------------------------------------------------------------------
function r = run_model(data, model_type, split_cal, ar_lookback, es_alpha, es_beta)
    // Fits one model on calendar rows 1..split_cal and evaluates it on the
    // common test window split_cal+1..n. model_type: "LR","AR","ES","NAIVE".
    // The test window is identical for every model type.
    n = data.n; close = data.close;
    MIN_TEST = 5; MIN_TRAIN_SAMPLES = 20;
    if split_cal < 1 | split_cal >= n then
        error("run_model: split leaves an empty train or test side (" + string(split_cal) + ..
              " / " + string(n) + " rows).");
    end
    if n - split_cal < MIN_TEST then
        error("run_model: test window has only " + string(n - split_cal) + " rows -- need at " + ..
              "least " + string(MIN_TEST) + ". Lower the train share.");
    end

    r = struct();
    r.model_type = model_type;
    r.split_cal = split_cal;
    r.test_idx = (split_cal+1:n)';
    r.ma_history = close(1:split_cal);

    if model_type == "LR" then
        feat = build_lr_features(data);
        split_idx = sum(feat.row_idx + 1 <= split_cal);   // targets inside the training window
        if split_idx < MIN_TRAIN_SAMPLES then
            error("Linear Regression: only " + string(split_idx) + " training samples after the " + ..
                  "10-row feature warm-up -- need at least " + string(MIN_TRAIN_SAMPLES) + ..
                  ". Raise the train share or load more rows.");
        end
        model = fit_lr_at(feat, split_idx);
        if or(model.row_idx_test + 1 <> r.test_idx) then
            error("run_model: internal test-window misalignment for LR.");
        end
        ev = evaluate_model(model);
        [np, lo, hi] = predict_next_lr(model);
        y_true = model.y_test; y_prev = model.y_prev_test;
        r.name = "Linear Regression"; r.label = "LR";
        r.n_train = split_idx;

    elseif model_type == "AR" then
        model = fit_ar_at(data, ar_lookback, split_cal - ar_lookback);
        ev = evaluate_ar_model(model);
        [np, lo, hi] = predict_next_ar(model);
        y_true = ev.y_test_real; y_prev = model.y_prev_test;
        r.name = "AR(" + string(ar_lookback) + ")"; r.label = "AR";
        r.n_train = model.split_idx;

    elseif model_type == "ES" then
        model = fit_es_at(data, split_cal, es_alpha, es_beta);
        ev = evaluate_es_model(model);
        [np, lo, hi] = predict_next_es(model);
        y_true = model.y_test; y_prev = model.y_prev_test;
        r.name = "Exp. Smoothing (a=" + string(es_alpha) + ", b=" + string(es_beta) + ")";
        r.label = "ES";
        r.n_train = split_cal;    // rows that build the smoothing state

    elseif model_type == "NAIVE" then
        // Tomorrow = today's close. No fitted parameters.
        if split_cal < 3 then error("run_model: naive baseline needs >= 3 training rows."); end
        y_true = close(split_cal+1:n); y_prev = close(split_cal:n-1);
        ev = compute_metrics(y_true, y_prev, y_prev);
        ev.y_pred = y_prev;
        np = close(n);
        sd = stdev(close(2:split_cal) - close(1:split_cal-1));
        lo = np - 1.96 * sd; hi = np + 1.96 * sd;
        model = struct();
        r.name = "Naive last-value"; r.label = "Naive";
        r.n_train = split_cal;
    else
        error("run_model: unknown model type [" + model_type + "].");
    end

    if size(y_true, 1) <> n - split_cal then
        error("run_model: test window length mismatch for " + model_type + ".");
    end

    r.model = model; r.metrics = ev;
    r.y_true = y_true(:); r.y_pred = ev.y_pred(:); r.y_prev = y_prev(:);
    r.n_test = size(y_true, 1);
    r.next_price = np; r.ci_lo = lo; r.ci_hi = hi;
endfunction


function rk = rank_models(M, labels)
    // Ranks models from a metric matrix (rows = models). Columns of M:
    // 1 RMSE, 2 MAE, 3 MAPE, 4 R^2, 5 DirAcc, 6 WF-RMSE, 7 WF-MAE, 8 WF-DirAcc.
    // Ranked metrics: RMSE, MAE, MAPE, DirAcc, WF-RMSE, WF-MAE; mean rank of
    // the available ones decides, ties broken by WF-RMSE then RMSE. R^2 is
    // not ranked separately (on one window it orders models like RMSE) and
    // a model with no value for a metric (naive direction) skips it.
    cols = [1 2 3 5 6 7];
    names = ["Test RMSE","Test MAE","Test MAPE","Direction accuracy","Walk-forward RMSE","Walk-forward MAE"];
    hib = [%f %f %f %t %f %f];
    nm = size(M, 1); nmet = size(cols, 2);
    ranks = zeros(nm, nmet) * %nan;
    for j = 1:nmet
        v = M(:, cols(j));
        ok = find(~isnan(v));
        if size(ok, "*") < 2 then continue; end
        vv = v(ok);
        if hib(j) then vv = -vv; end
        for a = 1:size(ok, "*")
            ranks(ok(a), j) = sum(vv < vv(a) - 1e-12) + 1;
        end
    end

    mean_rank = zeros(nm, 1) * %nan;
    for i = 1:nm
        rr = ranks(i, :);
        rr = rr(~isnan(rr));
        if size(rr, "*") > 0 then mean_rank(i) = mean(rr); end
    end

    // Sort by mean rank; tie-break by WF-RMSE then RMSE.
    wf = M(:, 6); wf(isnan(wf)) = 0;
    te = M(:, 1); te(isnan(te)) = 0;
    mr = mean_rank; mr(isnan(mr)) = 1e6;
    [dummy, order] = gsort(mr * 1e9 + wf * 1e3 + te, "g", "i");

    wins = repmat("", nm, 1);
    for i = 1:nm
        for j = 1:nmet
            if ranks(i, j) == 1 then
                if wins(i) <> "" then wins(i) = wins(i) + ", "; end
                wins(i) = wins(i) + names(j);
            end
        end
    end

    rk = struct();
    rk.labels = labels; rk.metric_names = names; rk.ranks = ranks;
    rk.mean_rank = mean_rank; rk.order = order(:); rk.wins = wins;
    rk.n_metrics_used = zeros(nm, 1);
    for i = 1:nm
        rk.n_metrics_used(i) = sum(~isnan(ranks(i, :)));
    end

    // Best of the three StockVision models (index 1 is the naive baseline).
    rk.best_idx = 0;
    for a = 1:size(order, "*")
        if order(a) > 1 then rk.best_idx = order(a); break; end
    end
    rk.skill_rmse = zeros(nm, 1) * %nan;
    rk.skill_wf_rmse = zeros(nm, 1) * %nan;
    for i = 2:nm
        if M(1, 1) > 0 then rk.skill_rmse(i) = (1 - M(i, 1) / M(1, 1)) * 100; end
        if M(1, 6) > 0 then rk.skill_wf_rmse(i) = (1 - M(i, 6) / M(1, 6)) * 100; end
    end
    rk.naive_rank_pos = find(order == 1);

    // Near-tie flag: top two StockVision models within 1% on test RMSE.
    rk.near_tie = %f; rk.tie_gap_pct = %nan;
    sv = []; for a = 1:size(order, "*"); if order(a) > 1 then sv = [sv; order(a)]; end; end
    if size(sv, "*") >= 2 then
        r1 = M(sv(1), 1); r2 = M(sv(2), 1);
        if r1 > 0 then
            rk.tie_gap_pct = abs(r2 - r1) / min(r1, r2) * 100;
            rk.near_tie = rk.tie_gap_pct < 1;
        end
    end
endfunction


function cmp = compare_models(data, split_ratio, ar_lookback, es_alpha, es_beta, n_folds_req)
    // Runs Naive, LR, AR and ES on the SAME dataset/split/test window with
    // the same metrics, adds walk-forward results and the ranking.
    keys = ["NAIVE", "LR", "AR", "ES"];
    labels = ["Naive"; "LR"; "AR"; "ES"];
    split_cal = round(data.n * split_ratio);

    results = list();
    for i = 1:4
        results($+1) = run_model(data, keys(i), split_cal, ar_lookback, es_alpha, es_beta);
    end
    wf = walk_forward_all(data, n_folds_req, ar_lookback, es_alpha, es_beta);

    M = zeros(4, 8) * %nan;
    for i = 1:4
        m = results(i).metrics;
        M(i, 1:5) = [m.rmse, m.mae, m.mape, m.r2, m.dir_acc];
        M(i, 6:8) = [wf.mean_rmse(i), wf.mean_mae(i), wf.mean_dir(i)];
    end

    cmp = struct();
    cmp.keys = keys; cmp.labels = labels; cmp.results = results; cmp.wf = wf;
    cmp.M = M; cmp.split_cal = split_cal; cmp.split_ratio = split_ratio;
    cmp.ar_lookback = ar_lookback; cmp.es_alpha = es_alpha; cmp.es_beta = es_beta;
    cmp.rank = rank_models(M, labels);
endfunction


// ---------------------------------------------------------------------------
// 5. Walk-forward validation
// ---------------------------------------------------------------------------
function wf = walk_forward_all(data, n_req, ar_lookback, es_alpha, es_beta)
    // Expanding-window validation for all four models on the same folds.
    // Fold f trains on rows 1..train_end(f) and tests on the next fold_size
    // rows. Each fold runs on data TRUNCATED at its own test end, so nothing
    // after the fold exists for the models. If the data cannot support
    // n_req folds the count is reduced and wf.reason says why.
    n = data.n;
    MIN_FOLD = 10;
    keys = ["NAIVE", "LR", "AR", "ES"];
    n_req = max(1, round(n_req));
    min_train = max([round(0.4 * n), 40, ar_lookback + 30]);
    max_folds = floor((n - min_train) / MIN_FOLD);
    if max_folds < 1 then
        error("Walk-forward needs at least " + string(min_train + MIN_FOLD) + " rows for this " + ..
              "setup (have " + string(n) + "). Load a longer dataset or use a shorter lookback.");
    end
    n_used = min(n_req, max_folds);
    reason = "";
    if n_used < n_req then
        reason = "Reduced from " + string(n_req) + " to " + string(n_used) + " fold(s): with " + ..
                 string(n) + " rows, " + string(min_train) + " are kept for initial training and " + ..
                 "each fold needs at least " + string(MIN_FOLD) + " test rows.";
    end
    fold_size = floor((n - min_train) / n_used);

    f_rmse = zeros(n_used, 4); f_mae = zeros(n_used, 4);
    f_mape = zeros(n_used, 4); f_dir = zeros(n_used, 4);
    train_end = zeros(n_used, 1); test_end = zeros(n_used, 1);

    for f = 1:n_used
        train_end(f) = min_train + (f - 1) * fold_size;
        test_end(f) = train_end(f) + fold_size;
        if f == n_used then test_end(f) = n; end
        d = slice_data(data, test_end(f));      // future rows removed
        for i = 1:4
            r = run_model(d, keys(i), train_end(f), ar_lookback, es_alpha, es_beta);
            f_rmse(f, i) = r.metrics.rmse; f_mae(f, i) = r.metrics.mae;
            f_mape(f, i) = r.metrics.mape; f_dir(f, i) = r.metrics.dir_acc;
        end
    end

    wf = struct();
    wf.keys = keys; wf.labels = ["Naive"; "LR"; "AR"; "ES"];
    wf.n_req = n_req; wf.n_used = n_used; wf.reason = reason;
    wf.n_total = n; wf.min_train = min_train; wf.fold_size = fold_size;
    wf.train_end = train_end; wf.test_end = test_end;
    wf.fold_rmse = f_rmse; wf.fold_mae = f_mae; wf.fold_mape = f_mape; wf.fold_dir = f_dir;
    wf.mean_rmse = mean(f_rmse, "r")'; wf.mean_mae = mean(f_mae, "r")';
    wf.mean_mape = mean(f_mape, "r")';
    wf.mean_dir = zeros(4, 1) * %nan;
    for i = 1:4
        v = f_dir(:, i); v = v(~isnan(v));
        if size(v, "*") > 0 then wf.mean_dir(i) = mean(v); end
    end
endfunction


// Legacy single-model walk-forward (per-model sample indexing), kept so the
// original API and its tests still work. The GUI uses walk_forward_all().
function results = walk_forward_validate(data, model_type, n_folds, ar_lookback)
    if model_type == "LR" then
        feat = build_lr_features(data);
        Xall = feat.X_raw; yall = feat.y; n = feat.n_valid;
    else
        p = ar_lookback;
        n_data = data.n;
        n = n_data - p;
        Xall = zeros(n, p); yall = zeros(n, 1);
        for i = 1:n
            Xall(i, :) = data.close(i:i+p-1)';
            yall(i) = data.close(i+p);
        end
    end

    min_train = max(20, round(n * 0.3));
    fold_size = floor((n - min_train) / n_folds);
    if fold_size < 1 then
        error("walk_forward_validate: not enough data for " + string(n_folds) + ..
              " folds -- use fewer folds or a longer dataset.");
    end

    fold_rmse = zeros(n_folds, 1); fold_mae = zeros(n_folds, 1);
    fold_mape = zeros(n_folds, 1); fold_r2 = zeros(n_folds, 1);
    fold_train_end = zeros(n_folds, 1); fold_test_end = zeros(n_folds, 1);

    for f = 1:n_folds
        train_end = min_train + (f-1)*fold_size;
        test_end = train_end + fold_size;
        if f == n_folds then test_end = n; end   // last fold absorbs the remainder
        fold_train_end(f) = train_end; fold_test_end(f) = test_end;

        Xtr = Xall(1:train_end, :); ytr = yall(1:train_end);
        Xte = Xall(train_end+1:test_end, :); yte = yall(train_end+1:test_end);

        mu = mean(Xtr, "r"); sigma = stdev(Xtr, "r"); sigma(sigma == 0) = 1;
        Xtr_s = (Xtr - repmat(mu, size(Xtr,1), 1)) ./ repmat(sigma, size(Xtr,1), 1);
        Xte_s = (Xte - repmat(mu, size(Xte,1), 1)) ./ repmat(sigma, size(Xte,1), 1);

        Xtr_aug = [ones(size(Xtr_s,1),1), Xtr_s];
        beta = Xtr_aug \ ytr;
        Xte_aug = [ones(size(Xte_s,1),1), Xte_s];
        pred = Xte_aug * beta;
        mt = compute_metrics(yte, pred);
        fold_rmse(f) = mt.rmse; fold_mae(f) = mt.mae;
        fold_mape(f) = mt.mape; fold_r2(f) = mt.r2;
    end
    results = wf_pack(fold_rmse, fold_mae, fold_mape, fold_r2, fold_train_end, ..
                      fold_test_end, n, min_train, n_folds);
endfunction


function results = walk_forward_validate_es(data, n_folds, alpha, beta)
    // Legacy ES walk-forward: slices of one continuous Holt recursion.
    close = data.close; n = data.n;
    min_train = max(20, round(n * 0.3));
    fold_size = floor((n - min_train) / n_folds);
    if fold_size < 1 then
        error("walk_forward_validate_es: not enough data for " + string(n_folds) + ..
              " folds -- use fewer folds or a longer dataset.");
    end

    [L, T, fcst] = holt_recursion(close, alpha, beta);

    fold_rmse = zeros(n_folds, 1); fold_mae = zeros(n_folds, 1);
    fold_mape = zeros(n_folds, 1); fold_r2 = zeros(n_folds, 1);
    fold_train_end = zeros(n_folds, 1); fold_test_end = zeros(n_folds, 1);

    for f = 1:n_folds
        train_end = min_train + (f-1)*fold_size;
        test_end = train_end + fold_size;
        if f == n_folds then test_end = n; end
        fold_train_end(f) = train_end; fold_test_end(f) = test_end;
        mt = compute_metrics(close(train_end+1:test_end), fcst(train_end+1:test_end));
        fold_rmse(f) = mt.rmse; fold_mae(f) = mt.mae;
        fold_mape(f) = mt.mape; fold_r2(f) = mt.r2;
    end
    results = wf_pack(fold_rmse, fold_mae, fold_mape, fold_r2, fold_train_end, ..
                      fold_test_end, n, min_train, n_folds);
endfunction


function results = wf_pack(fold_rmse, fold_mae, fold_mape, fold_r2, fold_train_end, ..
                           fold_test_end, n, min_train, n_folds)
    // Shared result struct for the legacy walk-forward functions.
    results = struct();
    results.fold_rmse = fold_rmse; results.fold_mae = fold_mae;
    results.fold_mape = fold_mape; results.fold_r2 = fold_r2;
    results.fold_train_end = fold_train_end; results.fold_test_end = fold_test_end;
    results.n_total = n; results.min_train = min_train; results.n_folds = n_folds;
    results.mean_rmse = mean(fold_rmse); results.mean_mae = mean(fold_mae);
    v = fold_mape(~isnan(fold_mape));
    if size(v, 1) > 0 then results.mean_mape = mean(v); else results.mean_mape = %nan; end
    v = fold_r2(~isnan(fold_r2));
    if size(v, 1) > 0 then results.mean_r2 = mean(v); else results.mean_r2 = %nan; end
endfunction


// ---------------------------------------------------------------------------
// 6. Signals and backtest
// ---------------------------------------------------------------------------
function signal = generate_signal(current_price, predicted_price, buy_threshold, sell_threshold)
    // BUY / SELL / HOLD from the predicted % change. SELL means "exit a long
    // position": the app never shorts.
    pct_change = (predicted_price - current_price) / current_price * 100;
    if pct_change >= buy_threshold then
        action = "BUY";
    elseif pct_change <= sell_threshold then
        action = "SELL";
    else
        action = "HOLD";
    end
    signal = struct();
    signal.action = action;
    signal.pct_change = pct_change;
endfunction


function ma = moving_average(series, window, history)
    // Trailing moving average of `series`. Optional `history` (values just
    // before series) fills the first window-1 points instead of leaving NaN.
    if argn(2) < 3 then
        history = [];
    end
    n = size(series, 1);
    ma = zeros(n, 1) * %nan;
    combined = [history; series];
    offset = size(history, 1);
    for i = 1:n
        w_end = offset + i;
        w_start = w_end - window + 1;
        if w_start >= 1 then
            ma(i) = mean(combined(w_start:w_end));
        end
    end
endfunction


function st = equity_stats(values)
    // Max drawdown %, annualized volatility % and Sharpe (rf = 0) for an
    // equity curve; 252 bars per year.
    n = size(values, 1);
    peak = values(1); max_dd = 0;
    for i = 1:n
        if values(i) > peak then peak = values(i); end
        dd = (peak - values(i)) / peak * 100;
        if dd > max_dd then max_dd = dd; end
    end
    dr = zeros(max(n-1, 0), 1);
    for i = 2:n
        dr(i-1) = (values(i) - values(i-1)) / values(i-1);
    end
    st = struct();
    st.max_drawdown_pct = max_dd;
    st.volatility_pct = %nan; st.sharpe = %nan;
    if size(dr, 1) >= 2 then
        s = stdev(dr);
        st.volatility_pct = s * sqrt(252) * 100;
        if s > 1e-12 then st.sharpe = mean(dr) / s * sqrt(252); end
    end
    st.daily_returns = dr;
endfunction


function bt = run_backtest(y_actual, y_pred, buy_threshold, sell_threshold, starting_capital, ..
                            transaction_cost_pct, slippage_pct)
    // Long-only, all-in/all-out simulation over the evaluation window.
    // y_pred(i) is the forecast of y_actual(i) made with data through i-1.
    //
    // Timing: the signal at day i (forecast vs close(i-1)) trades at the
    // close of day i and only exposes the portfolio to returns from day i+1.
    // The loop books day i's return BEFORE deciding day i's signal, so a
    // signal can never earn a return that already happened.
    //
    // Costs: (transaction_cost_pct + slippage_pct)/100 of portfolio value is
    // deducted on every executed BUY and SELL. Buy & hold is invested from
    // the first day and pays one entry cost. Percent inputs, default 0.
    if argn(2) < 7 then slippage_pct = 0; end
    if argn(2) < 6 then transaction_cost_pct = 0; end

    // A NaN/non-positive price would corrupt the whole multiplicative chain.
    // A NaN y_pred is harmless (fails both thresholds -> HOLD).
    if or(isnan(y_actual)) | or(y_actual <= 0) then
        error("run_backtest: y_actual contains a NaN or non-positive price -- clean the data " + ..
              "(e.g. via load_dataset()) before backtesting.");
    end

    cost_frac = (transaction_cost_pct + slippage_pct) / 100;

    n = size(y_actual, 1);
    strategy_value = zeros(n, 1);
    buyhold_value = zeros(n, 1);
    position = zeros(n, 1);          // 1 if long after day i's trade
    in_position = %f;
    n_trades = 0;
    entry_price = %nan; entry_idx = 0;
    trade_gross = []; trade_net = []; trade_entry = []; trade_exit = [];

    strategy_value(1) = starting_capital;
    buyhold_value(1) = starting_capital * (1 - cost_frac);

    for i = 2:n
        day_return = (y_actual(i) - y_actual(i-1)) / y_actual(i-1);

        if in_position then
            strategy_value(i) = strategy_value(i-1) * (1 + day_return);
        else
            strategy_value(i) = strategy_value(i-1);
        end
        buyhold_value(i) = buyhold_value(i-1) * (1 + day_return);

        prev_price = y_actual(i-1);
        pct = (y_pred(i) - prev_price) / prev_price * 100;
        if pct >= buy_threshold then
            action = "BUY";
        elseif pct <= sell_threshold then
            action = "SELL";
        else
            action = "HOLD";
        end

        if action == "BUY" & ~in_position then
            strategy_value(i) = strategy_value(i) * (1 - cost_frac);
            in_position = %t;
            n_trades = n_trades + 1;
            entry_price = y_actual(i); entry_idx = i;
        elseif action == "SELL" & in_position then
            strategy_value(i) = strategy_value(i) * (1 - cost_frac);
            in_position = %f;
            n_trades = n_trades + 1;
            g = (y_actual(i) - entry_price) / entry_price;
            trade_gross = [trade_gross; g];
            trade_net = [trade_net; (1 + g) * (1 - cost_frac)^2 - 1];   // entry + exit cost
            trade_entry = [trade_entry; entry_idx]; trade_exit = [trade_exit; i];
        end
        if in_position then position(i) = 1; end
    end

    s_stats = equity_stats(strategy_value);
    b_stats = equity_stats(buyhold_value);

    n_completed = size(trade_net, 1);
    n_wins = 0; n_losses = 0;
    if n_completed > 0 then
        n_wins = sum(trade_net > 0); n_losses = sum(trade_net < 0);
        win_rate_pct = n_wins / n_completed * 100;
    else
        win_rate_pct = %nan;
    end

    n_days = max(n - 1, 0);
    ann_s = %nan; ann_b = %nan;
    if n_days >= 30 then          // shorter windows are too noisy to annualize
        yrs = n_days / 252;
        ann_s = ((strategy_value($) / starting_capital)^(1/yrs) - 1) * 100;
        ann_b = ((buyhold_value($) / starting_capital)^(1/yrs) - 1) * 100;
    end

    bt = struct();
    bt.starting_capital = starting_capital;
    bt.strategy_value = strategy_value;
    bt.buyhold_value = buyhold_value;
    bt.position = position;
    bt.n_trades = n_trades;
    bt.strategy_final = strategy_value($);
    bt.buyhold_final = buyhold_value($);
    bt.strategy_return_pct = (strategy_value($) - starting_capital) / starting_capital * 100;
    bt.buyhold_return_pct = (buyhold_value($) - starting_capital) / starting_capital * 100;
    bt.annualized_return_pct = ann_s;
    bt.buyhold_annualized_pct = ann_b;
    bt.max_drawdown_pct = s_stats.max_drawdown_pct;
    bt.buyhold_max_drawdown_pct = b_stats.max_drawdown_pct;
    bt.sharpe_ratio = s_stats.sharpe;
    bt.buyhold_sharpe = b_stats.sharpe;
    bt.volatility_pct_annualized = s_stats.volatility_pct;
    bt.buyhold_volatility_pct = b_stats.volatility_pct;
    bt.win_rate_pct = win_rate_pct;
    bt.n_completed_trades = n_completed;
    bt.n_wins = n_wins; bt.n_losses = n_losses;
    bt.n_breakeven = n_completed - n_wins - n_losses;
    bt.open_position_at_end = in_position;
    bt.trade_gross = trade_gross; bt.trade_net = trade_net;
    bt.trade_entry = trade_entry; bt.trade_exit = trade_exit;
    bt.transaction_cost_pct = transaction_cost_pct;
    bt.slippage_pct = slippage_pct;
    bt.buy_threshold = buy_threshold; bt.sell_threshold = sell_threshold;
    bt.n_days = n_days;
    bt.exec_lag_days = 1;
endfunction


// ---------------------------------------------------------------------------
// 7. Text reports (shared by GUI panels and exported files; ASCII only)
// ---------------------------------------------------------------------------
function s = fmt_num(v, nd)
    // Fixed-decimal number, or "n/a" for empty/NaN.
    if size(v, "*") == 0 then
        s = "n/a";
    elseif isnan(v) then
        s = "n/a";
    else
        s = msprintf("%." + string(nd) + "f", v);
    end
endfunction


function s = fmt_pct(v, nd)
    s = fmt_num(v, nd);
    if s <> "n/a" then s = s + "%"; end
endfunction


function s = fmt_signed_pct(v, nd)
    s = fmt_num(v, nd);
    if s <> "n/a" then
        if v >= 0 then s = "+" + s; end
        s = s + "%";
    end
endfunction


function cells = metric_cells(vals, nd, higher_better, suffix)
    // Right-aligned 9-char cells for one table row. The best value (ties
    // included) gets a trailing '*' when at least two values are comparable.
    k = size(vals, "*");
    cells = repmat("", 1, k);
    ok = ~isnan(vals);
    best = %nan;
    if or(ok) then
        if higher_better then best = max(vals(ok)); else best = min(vals(ok)); end
    end
    for j = 1:k
        if isnan(vals(j)) then
            c = "n/a";
        else
            c = msprintf("%." + string(nd) + "f", vals(j)) + suffix;
            if sum(ok) > 1 & abs(vals(j) - best) <= 1e-12 * max(1, abs(best)) then
                c = c + "*";
            end
        end
        cells(j) = msprintf("%9s", c);
    end
endfunction


function lines = format_data_quality(dq, label)
    // Compact data-quality block (dataset name goes in the report header).
    if dq.chronological then chrono = "YES"; else chrono = "NO (sorted on load)"; end
    lines = [ ..
        "Rows:                " + string(dq.rows); ..
        "Date range:          " + dq.date_first + " -> " + dq.date_last; ..
        "Missing values:      " + fmt_num(dq.missing_remaining, 0) + " (" + string(dq.missing_dropped) + " rows dropped on load)"; ..
        "Duplicate dates:     " + string(dq.duplicates) + " (rejected on load)"; ..
        "Chronological order: " + chrono; ..
        "Invalid OHLC rows:   " + string(dq.invalid_ohlc) + " (dropped on load)"; ..
        "Training rows:       " + string(dq.train_rows) + "  (to " + dq.train_last + ")"; ..
        "Testing rows:        " + string(dq.test_rows) + "  (from " + dq.test_first + ")" ];
endfunction


function lines = format_model_results(r, naive_r, sig, validated)
    // Single-model panel: forecast, test metrics, baseline check, status.
    m = r.metrics;
    if validated then status = "VALIDATED (walk-forward run)"; else status = "READY"; end
    lines = [ ..
        "Model:            " + r.name; ..
        "Prediction:       " + fmt_num(r.next_price, 2) + "  (next close)"; ..
        "Current close:    " + fmt_num(sig.current_price, 2) + "  (" + fmt_signed_pct(sig.pct_change, 2) + " predicted)"; ..
        "Signal:           " + sig.action + "  (BUY >= " + fmt_num(sig.buy_thr, 2) + "%, SELL <= " + fmt_num(sig.sell_thr, 2) + "%)"; ..
        "Actual/Test RMSE: " + fmt_num(m.rmse, 4); ..
        "MAE:              " + fmt_num(m.mae, 4); ..
        "MAPE:             " + fmt_pct(m.mape, 3); ..
        "R^2:              " + fmt_num(m.r2, 4); ..
        "Direction acc.:   " + fmt_pct(m.dir_acc, 1)];
    if r.model_type == "NAIVE" then
        lines = [lines; "Baseline:         this IS the naive forecast"];
    else
        skill = (1 - m.rmse / naive_r.metrics.rmse) * 100;
        if skill > 0 then verdict = "beats"; else verdict = "does NOT beat"; end
        lines = [lines; "Naive RMSE:       " + fmt_num(naive_r.metrics.rmse, 4) + "  -> " + verdict + " naive (" + fmt_signed_pct(skill, 1) + ")"];
    end
    lines = [lines; ..
        "Train samples:    " + string(r.n_train); ..
        "Test samples:     " + string(r.n_test); ..
        "Model status:     " + status];
endfunction


function lines = format_comparison(cmp)
    // Metric table across Naive / LR / AR / ES on one common test window.
    M = cmp.M;
    lines = [ ..
        string(cmp.results(1).n_test) + " test rows, " + string(cmp.wf.n_used) + " WF folds; * = best in row"; ..
        msprintf("%-17s", "Metric") + msprintf("%9s", "Naive") + msprintf("%9s", "LR") + ..
            msprintf("%9s", "AR") + msprintf("%9s", "ES"); ..
        "-----------------------------------------------------"];
    spec = list(list("RMSE", 1, 4, %f, ""), list("MAE", 2, 4, %f, ""), ..
                list("MAPE", 3, 3, %f, "%"), list("R^2", 4, 4, %t, ""), ..
                list("Direction acc.", 5, 1, %t, "%"), list("Walk-fwd RMSE", 6, 4, %f, ""), ..
                list("Walk-fwd MAE", 7, 4, %f, ""));
    for k = 1:size(spec)
        sp = spec(k);
        cells = metric_cells(M(:, sp(2))', sp(3), sp(4), sp(5));
        lines = [lines; msprintf("%-17s", sp(1)) + strcat(cells, "")];
    end
endfunction


function lines = format_ranking(cmp)
    // Ranking text; every statement is derived from cmp.M / cmp.rank.
    rk = cmp.rank; lab = cmp.labels;
    nmet = max(rk.n_metrics_used);
    lines = ["MODEL RANKING (mean rank over " + string(nmet) + " metrics; lower = better)"];
    row = ""; place = 0;
    for a = 1:size(rk.order, 1)
        i = rk.order(a);
        if i > 1 then
            place = place + 1;
            row = row + msprintf("%d. %s %s   ", place, lab(i), fmt_num(rk.mean_rank(i), 2));
        end
    end
    lines = [lines; row + "| Naive " + fmt_num(rk.mean_rank(1), 2)];
    b = rk.best_idx;
    w = rk.wins(b);
    n_w = sum(rk.ranks(b, :) == 1);
    if n_w == 0 then
        why = "best average rank (no outright win)";
    elseif n_w > 2 then
        why = "best on " + string(n_w) + " of " + string(nmet) + " metrics";
    else
        why = "best on " + w;
    end
    lines = [lines; "Best StockVision model: " + lab(b) + " -- " + why];
    if rk.near_tie then
        lines = [lines; "Note: top two differ by only " + fmt_num(rk.tie_gap_pct, 2) + "% RMSE (near-tie)."];
    end
    vs = "RMSE vs naive:"; beat = "";
    for i = 2:4
        if ~isnan(rk.skill_rmse(i)) then
            vs = vs + "  " + lab(i) + " " + fmt_signed_pct(rk.skill_rmse(i), 1);
            if rk.skill_rmse(i) > 0 then beat = beat + lab(i) + " "; end
        end
    end
    lines = [lines; vs];
    if beat == "" then
        lines = [lines; "No StockVision model beat the naive baseline on test RMSE."];
    else
        lines = [lines; "Beats naive on test RMSE: " + stripblanks(beat)];
    end
endfunction


function lines = format_walk_forward(wf)
    lines = ["Expanding window: train on all earlier rows, test on the next block."];
    lines = [lines; "Folds: " + string(wf.n_used) + " used (" + string(wf.n_req) + " requested); first train block " + ..
             string(wf.min_train) + " rows."];
    if wf.reason <> "" then
        lines = [lines; "Folds reduced: " + string(wf.n_total) + " rows, " + string(wf.min_train) + " kept for first training block,"; ..
                 "each fold needs >= 10 test rows."];
    end
    lines = [lines; msprintf("%-5s", "Fold") + msprintf("%-12s", "Test rows") + msprintf("%9s", "Naive") + ..
             msprintf("%9s", "LR") + msprintf("%9s", "AR") + msprintf("%9s", "ES") + "  (RMSE)"];
    for f = 1:wf.n_used
        rng = string(wf.train_end(f) + 1) + "-" + string(wf.test_end(f));
        cells = metric_cells(wf.fold_rmse(f, :), 4, %f, "");
        lines = [lines; msprintf("%-5s", string(f)) + msprintf("%-12s", rng) + strcat(cells, "")];
    end
    lines = [lines; "-----------------------------------------------------"];
    lines = [lines; msprintf("%-17s", "Mean RMSE") + strcat(metric_cells(wf.mean_rmse', 4, %f, ""), "")];
    lines = [lines; msprintf("%-17s", "Mean MAE") + strcat(metric_cells(wf.mean_mae', 4, %f, ""), "")];
    lines = [lines; msprintf("%-17s", "Mean Dir. acc.") + strcat(metric_cells(wf.mean_dir', 1, %t, "%"), "")];
endfunction


function c = bt_row(a, b)
    // One two-column row of the backtest table: label, strategy, buy & hold.
    c = msprintf("%-22s", a(1)) + msprintf("%13s", a(2)) + msprintf("%13s", b);
endfunction


function lines = format_backtest(bt, model_name)
    // Strategy vs buy & hold over the same evaluation window.
    diff_pts = bt.strategy_return_pct - bt.buyhold_return_pct;
    if diff_pts >= 0 then verdict = "AHEAD of"; else verdict = "BEHIND"; end
    lines = [ ..
        msprintf("%-22s", "") + msprintf("%13s", "Strategy") + msprintf("%13s", "Buy & Hold"); ..
        bt_row(["Starting capital", fmt_num(bt.starting_capital, 2)], fmt_num(bt.starting_capital, 2)); ..
        bt_row(["Ending capital", fmt_num(bt.strategy_final, 2)], fmt_num(bt.buyhold_final, 2)); ..
        bt_row(["Total return", fmt_signed_pct(bt.strategy_return_pct, 2)], fmt_signed_pct(bt.buyhold_return_pct, 2)); ..
        bt_row(["Annualized return*", fmt_signed_pct(bt.annualized_return_pct, 1)], fmt_signed_pct(bt.buyhold_annualized_pct, 1)); ..
        bt_row(["Max drawdown", fmt_pct(bt.max_drawdown_pct, 2)], fmt_pct(bt.buyhold_max_drawdown_pct, 2)); ..
        bt_row(["Volatility (ann.)", fmt_pct(bt.volatility_pct_annualized, 2)], fmt_pct(bt.buyhold_volatility_pct, 2)); ..
        bt_row(["Sharpe (rf=0)", fmt_num(bt.sharpe_ratio, 2)], fmt_num(bt.buyhold_sharpe, 2)); ..
        "Trades executed: " + string(bt.n_trades) + "   Round trips: " + string(bt.n_completed_trades); ..
        "Winning: " + string(bt.n_wins) + "   Losing: " + string(bt.n_losses) + "   Win rate: " + fmt_pct(bt.win_rate_pct, 1); ..
        "Strategy is " + verdict + " buy & hold by " + fmt_num(abs(diff_pts), 2) + " pts."];
    if bt.open_position_at_end then
        lines = [lines; "Position still open at the end (not a trade)."];
    end
    if isnan(bt.annualized_return_pct) then
        lines = [lines; "* needs >= 30 days of data"];
    else
        lines = [lines; "* annualized from " + string(bt.n_days) + " days: short-window extrapolation"];
    end
endfunction


function s = format_backtest_headline(bt)
    s = "Return " + fmt_signed_pct(bt.strategy_return_pct, 2) + " (B&H " + fmt_signed_pct(bt.buyhold_return_pct, 2) + ..
        ")  |  Max drawdown " + fmt_pct(bt.max_drawdown_pct, 2) + " (B&H " + fmt_pct(bt.buyhold_max_drawdown_pct, 2) + ..
        ")  |  Sharpe " + fmt_num(bt.sharpe_ratio, 2) + "  |  Win rate " + fmt_pct(bt.win_rate_pct, 1);
endfunction


function lines = format_assumptions(p)
    // Backtest assumptions, shown before and after a backtest is run.
    // p: capital, cost, slip, buy, sell, train/test first+last dates and row counts.
    lines = [ ..
        "Initial capital:  " + fmt_num(p.capital, 2); ..
        "Costs per trade:  " + fmt_num(p.cost, 3) + "% transaction + " + fmt_num(p.slip, 3) + "% slippage"; ..
        "Signal lag:       signal uses data through close of day T;"; ..
        "                  trade at close of T+1; first return"; ..
        "                  earned is T+1 -> T+2 (no look-ahead)"; ..
        "Position rule:    long-only, all-in/all-out; no shorting,"; ..
        "                  no leverage, no interest on cash"; ..
        "Entry/exit:       BUY if forecast >= " + fmt_signed_pct(p.buy, 2) + ", SELL if <= " + fmt_signed_pct(p.sell, 2); ..
        "Train period:     " + p.train_first + " -> " + p.train_last + " (" + string(p.train_rows) + " rows)"; ..
        "Test period:      " + p.test_first + " -> " + p.test_last + " (" + string(p.test_rows) + " rows)"; ..
        "Execution:        daily close; no rebalancing between signals"; ..
        "Benchmark:        buy & hold, same period, one entry cost"; ..
        "Risk stats:       252 bars/year, risk-free rate 0"];
endfunction


function lines = model_info_text(model_type, ar_lookback, es_alpha, es_beta)
    // Plain-language model description for the Model Info dialog/report.
    if model_type == "LR" then
        lines = [ ..
            "LINEAR REGRESSION"; " "; ..
            "Purpose:"; ..
            "  Predict the next closing price from engineered features."; " "; ..
            "Features (12, all known at the close of day t):"; ..
            "  Open, High, Low, Close, Volume, 1-day return, 5- and 10-day"; ..
            "  moving averages, 5-day volatility, lagged closes (1, 2, 3)."; " "; ..
            "Method: ordinary least squares on features standardized with"; ..
            "  TRAINING-period mean/std only (no test information)."; " "; ..
            "Assumptions:"; ..
            "  - the relationship is approximately linear"; ..
            "  - historical relationships remain useful out of sample"; ..
            "  - the features carry enough predictive information"; " "; ..
            "Limitations:"; ..
            "  - cannot capture nonlinear market dynamics"; ..
            "  - sensitive to regime changes; relationships may not persist"; ..
            "  - features are highly correlated (OHLC/MA/lags), so single"; ..
            "    coefficients are unstable even when forecasts are fine"];
    elseif model_type == "AR" then
        lines = [ ..
            "AR (AUTOREGRESSIVE) MODEL"; " "; ..
            "Purpose:"; ..
            "  Predict the next close from the last " + string(ar_lookback) + " closes."; " "; ..
            "Lookback window: " + string(ar_lookback) + " days (set in the Parameters panel)."; ..
            "Autoregressive assumption: tomorrow is a linear combination of"; ..
            "  recent past prices plus an intercept."; ..
            "Estimation: linear least squares on prices scaled to [0,1]"; ..
            "  using the TRAINING period min/max only."; ..
            "Short-memory assumption: only the last " + string(ar_lookback) + " days matter;"; ..
            "  anything older is ignored."; " "; ..
            "It is a linear model. It is NOT an LSTM, NOT a neural network,"; ..
            "and has no gates, nonlinearity or learned memory."; " "; ..
            "Limitations:"; ..
            "  - linear and short-memory; misses regime shifts and jumps"; ..
            "  - no exogenous inputs (volume, news, macro)"; ..
            "  - one fixed lookback for all market conditions"];
    elseif model_type == "ES" then
        lines = [ ..
            "EXPONENTIAL SMOOTHING (HOLT LINEAR TREND)"; " "; ..
            "Purpose:"; ..
            "  Track a smoothed price level and trend; forecast one step"; ..
            "  ahead as level + trend."; " "; ..
            "Level: smoothed price estimate, update weight alpha = " + string(es_alpha); ..
            "Trend: smoothed daily change, update weight beta = " + string(es_beta); ..
            "One-step forecasting: the forecast for day t uses only the state"; ..
            "  built from days before t, then the state is updated."; ..
            "Parameters: alpha and beta are FIXED defaults, not fitted to the"; ..
            "  data (so nothing is tuned on the test period, but they are"; ..
            "  also not optimal for any particular series)."; " "; ..
            "Limitations:"; ..
            "  - fixed alpha/beta; a poor choice lags or over-reacts"; ..
            "  - extrapolates the recent trend; weak at turning points"; ..
            "  - uses no volume or other features"];
    else
        lines = [ ..
            "NAIVE LAST-VALUE BASELINE"; " "; ..
            "Forecast for tomorrow = today close. No fitted parameters."; ..
            "Any real model should beat this on the same test window;"; ..
            "if it does not, that is reported as-is."];
    end
endfunction


// ---------------------------------------------------------------------------
// 8. Export (file writing only, no GUI)
// ---------------------------------------------------------------------------
function s = safe_str(v)
    // Any value -> one-line string (multi-element input is joined with "; ").
    if type(v) == 10 & size(v, "*") <= 1 then
        if size(v, "*") == 0 then s = ""; else s = v; end
    elseif size(v, "*") == 0 then
        s = "n/a";
    elseif size(v, "*") == 1 then
        s = string(v);
    else
        parts = string(v);
        s = parts(1);
        for k = 2:size(parts, "*")
            s = s + "; " + parts(k);
        end
    end
endfunction


function acc = append_line(acc, piece)
    // Appends one guaranteed-scalar line to a column of strings (avoids
    // "inconsistent row/column dimensions" from unexpectedly shaped pieces).
    line1 = safe_str(piece);
    if size(acc, "*") == 0 then
        acc = line1;
    else
        acc = [acc; line1];
    end
endfunction


function s = timestamp_string()
    c = clock();
    s = msprintf("%04d-%02d-%02d %02d:%02d:%02d", c(1), c(2), c(3), c(4), c(5), floor(c(6)));
endfunction


function p = unique_path(path)
    // Never overwrites: returns path, or path with _2, _3, ... before the extension.
    p = path;
    if ~isfile(p) then return; end
    [pth, nm, ext] = fileparts(path);
    k = 2;
    while isfile(pth + nm + "_" + string(k) + ext)
        k = k + 1;
    end
    p = pth + nm + "_" + string(k) + ext;
endfunction


function write_lines(path, lines)
    fd = mopen(path, "w");
    mputl(lines, fd);
    mclose(fd);
endfunction


function lines = build_report_lines(rep)
    // Full human-readable report. rep fields: dataset_label, data, dq, cfg,
    // analysis, naive, signal, validated, cmp, bt (empty [] when not run).
    cfg = rep.cfg;
    rule = "============================================================";
    lines = [];
    lines = append_line(lines, "STOCKVISION RESULTS REPORT");
    lines = append_line(lines, "Generated: " + timestamp_string());
    lines = append_line(lines, rule);
    lines = append_line(lines, "DATA QUALITY");
    lines = append_line(lines, "Dataset: " + rep.dataset_label);
    d = format_data_quality(rep.dq, rep.dataset_label);
    for k = 1:size(d, 1); lines = append_line(lines, d(k)); end

    lines = append_line(lines, rule);
    lines = append_line(lines, "PARAMETERS");
    lines = append_line(lines, "Train/test split:  " + string(round(cfg.split_ratio*100)) + "% / " + string(round((1-cfg.split_ratio)*100)) + "%");
    lines = append_line(lines, "AR lookback:       " + string(cfg.ar_lookback) + " days");
    lines = append_line(lines, "ES parameters:     alpha=" + string(cfg.es_alpha) + ", beta=" + string(cfg.es_beta) + " (fixed)");
    lines = append_line(lines, "Walk-forward:      " + string(cfg.n_folds) + " folds requested");
    lines = append_line(lines, "Signal thresholds: BUY >= " + string(cfg.buy) + "%, SELL <= " + string(cfg.sell) + "%");
    lines = append_line(lines, "Transaction cost:  " + string(cfg.cost) + "%   Slippage: " + string(cfg.slip) + "%");

    if typeof(rep.analysis) == "st" then
        lines = append_line(lines, rule);
        lines = append_line(lines, "SELECTED MODEL RESULTS");
        d = format_model_results(rep.analysis, rep.naive, rep.signal, rep.validated);
        for k = 1:size(d, 1); lines = append_line(lines, d(k)); end
    end
    if typeof(rep.cmp) == "st" then
        lines = append_line(lines, rule);
        lines = append_line(lines, "MODEL COMPARISON");
        d = [format_comparison(rep.cmp); " "; format_ranking(rep.cmp)];
        for k = 1:size(d, 1); lines = append_line(lines, d(k)); end
        lines = append_line(lines, rule);
        lines = append_line(lines, "WALK-FORWARD VALIDATION");
        d = format_walk_forward(rep.cmp.wf);
        for k = 1:size(d, 1); lines = append_line(lines, d(k)); end
    end
    lines = append_line(lines, rule);
    lines = append_line(lines, "BACKTEST ASSUMPTIONS");
    d = format_assumptions(rep.assump);
    for k = 1:size(d, 1); lines = append_line(lines, d(k)); end
    if typeof(rep.bt) == "st" then
        lines = append_line(lines, rule);
        lines = append_line(lines, "BACKTEST RESULTS");
        d = format_backtest(rep.bt, rep.analysis.name);
        for k = 1:size(d, 1); lines = append_line(lines, d(k)); end
    end
    lines = append_line(lines, rule);
    lines = append_line(lines, "Educational tool, not financial advice. Bundled datasets are");
    lines = append_line(lines, "synthetic. Historical results do not predict future returns.");
endfunction


function export_report_txt(path, rep)
    write_lines(path, build_report_lines(rep));
endfunction


function export_results_csv(path, rep)
    // Metric,Value block (selected model, backtest if run) followed by the
    // actual-vs-predicted test-window table.
    cfg = rep.cfg; r = rep.analysis; m = r.metrics; dq = rep.dq;
    L = [];
    L = append_line(L, "Metric,Value");
    L = append_line(L, "Timestamp," + timestamp_string());
    L = append_line(L, "Dataset," + safe_str(rep.dataset_label));
    L = append_line(L, "Date_First," + dq.date_first);
    L = append_line(L, "Date_Last," + dq.date_last);
    L = append_line(L, "Model," + safe_str(r.name));
    L = append_line(L, "Rows_Used," + safe_str(dq.rows));
    L = append_line(L, "Train_Pct," + safe_str(round(cfg.split_ratio*100)));
    L = append_line(L, "Test_Pct," + safe_str(round((1-cfg.split_ratio)*100)));
    L = append_line(L, "Train_Samples," + safe_str(r.n_train));
    L = append_line(L, "Test_Samples," + safe_str(r.n_test));
    L = append_line(L, "AR_Lookback," + safe_str(cfg.ar_lookback));
    L = append_line(L, "ES_Alpha," + safe_str(cfg.es_alpha));
    L = append_line(L, "ES_Beta," + safe_str(cfg.es_beta));
    L = append_line(L, "RMSE," + safe_str(m.rmse));
    L = append_line(L, "MAE," + safe_str(m.mae));
    L = append_line(L, "MAPE_pct," + safe_str(m.mape));
    L = append_line(L, "R2," + safe_str(m.r2));
    L = append_line(L, "Direction_Accuracy_pct," + safe_str(m.dir_acc));
    L = append_line(L, "Prediction_Accuracy_pct," + safe_str(m.accuracy_pct));
    L = append_line(L, "Naive_RMSE," + safe_str(rep.naive.metrics.rmse));
    L = append_line(L, "Current_Price," + safe_str(rep.signal.current_price));
    L = append_line(L, "Predicted_Next_Price," + safe_str(r.next_price));
    L = append_line(L, "Rough_Band_Low_NOT_a_true_prediction_interval," + safe_str(r.ci_lo));
    L = append_line(L, "Rough_Band_High_NOT_a_true_prediction_interval," + safe_str(r.ci_hi));
    L = append_line(L, "Predicted_Change_pct," + safe_str(rep.signal.pct_change));
    L = append_line(L, "Signal," + safe_str(rep.signal.action));
    L = append_line(L, "Buy_Threshold_pct," + safe_str(cfg.buy));
    L = append_line(L, "Sell_Threshold_pct," + safe_str(cfg.sell));
    if typeof(rep.cmp) == "st" then
        lab = rep.cmp.labels; M = rep.cmp.M;
        for i = 1:4
            L = append_line(L, "WalkForward_RMSE_" + lab(i) + "," + safe_str(M(i, 6)));
        end
        L = append_line(L, "Best_Model," + lab(rep.cmp.rank.best_idx));
    end
    if typeof(rep.bt) == "st" then
        bt = rep.bt;
        L = append_line(L, "Backtest_Starting_Capital," + safe_str(bt.starting_capital));
        L = append_line(L, "Backtest_Ending_Capital," + safe_str(bt.strategy_final));
        L = append_line(L, "Backtest_Trades_Made," + safe_str(bt.n_trades));
        L = append_line(L, "Backtest_Completed_RoundTrips," + safe_str(bt.n_completed_trades));
        L = append_line(L, "Backtest_Winning_Trades," + safe_str(bt.n_wins));
        L = append_line(L, "Backtest_Losing_Trades," + safe_str(bt.n_losses));
        L = append_line(L, "Backtest_Transaction_Cost_pct," + safe_str(bt.transaction_cost_pct));
        L = append_line(L, "Backtest_Slippage_pct," + safe_str(bt.slippage_pct));
        L = append_line(L, "Backtest_Strategy_Return_pct," + safe_str(bt.strategy_return_pct));
        L = append_line(L, "Backtest_Annualized_Return_pct," + safe_str(bt.annualized_return_pct));
        L = append_line(L, "Backtest_BuyHold_Final," + safe_str(bt.buyhold_final));
        L = append_line(L, "Backtest_BuyHold_Return_pct," + safe_str(bt.buyhold_return_pct));
        L = append_line(L, "Backtest_Max_Drawdown_pct," + safe_str(bt.max_drawdown_pct));
        L = append_line(L, "Backtest_BuyHold_Max_Drawdown_pct," + safe_str(bt.buyhold_max_drawdown_pct));
        L = append_line(L, "Backtest_Annualized_Volatility_pct," + safe_str(bt.volatility_pct_annualized));
        L = append_line(L, "Backtest_Sharpe_Ratio," + safe_str(bt.sharpe_ratio));
        L = append_line(L, "Backtest_Win_Rate_pct," + safe_str(bt.win_rate_pct));
    end
    L = append_line(L, "");
    L = append_line(L, "Index,Date,Actual,Predicted");
    for i = 1:r.n_test
        L = append_line(L, string(i) + "," + rep.data.dates(r.test_idx(i)) + "," + ..
                        safe_str(r.y_true(i)) + "," + safe_str(r.y_pred(i)));
    end
    write_lines(path, L);
endfunction


function written = export_companion_csvs(base, rep)
    // Extra tables next to the TXT report: <base>_predictions.csv,
    // _comparison.csv, _walkforward.csv, _backtest.csv (only what exists).
    // Existing files are never overwritten. Returns the paths written.
    written = [];
    r = rep.analysis;
    if typeof(rep.cmp) == "st" then
        res = rep.cmp.results;
        L = "Index,Date,Actual,Naive,LR,AR,ES";
        for i = 1:r.n_test
            row = string(i) + "," + rep.data.dates(res(1).test_idx(i)) + "," + safe_str(res(1).y_true(i));
            for k = 1:4
                row = row + "," + safe_str(res(k).y_pred(i));
            end
            L = append_line(L, row);
        end
    else
        L = "Index,Date,Actual,Predicted";
        for i = 1:r.n_test
            L = append_line(L, string(i) + "," + rep.data.dates(r.test_idx(i)) + "," + ..
                            safe_str(r.y_true(i)) + "," + safe_str(r.y_pred(i)));
        end
    end
    p = unique_path(base + "_predictions.csv"); write_lines(p, L); written = [written; p];

    if typeof(rep.cmp) == "st" then
        lab = rep.cmp.labels; M = rep.cmp.M;
        names = ["RMSE","MAE","MAPE_pct","R2","Direction_Accuracy_pct","WalkForward_RMSE","WalkForward_MAE","WalkForward_Direction_Accuracy_pct"];
        L = "Metric," + strcat(lab', ",");
        for j = 1:8
            row = names(j);
            for i = 1:4; row = row + "," + safe_str(M(i, j)); end
            L = append_line(L, row);
        end
        p = unique_path(base + "_comparison.csv"); write_lines(p, L); written = [written; p];

        wf = rep.cmp.wf;
        L = "Fold,Train_Rows,Test_First_Row,Test_Last_Row,Model,RMSE,MAE,MAPE_pct,Direction_Accuracy_pct";
        for f = 1:wf.n_used
            for i = 1:4
                L = append_line(L, string(f) + "," + string(wf.train_end(f)) + "," + string(wf.train_end(f)+1) + "," + ..
                    string(wf.test_end(f)) + "," + wf.labels(i) + "," + safe_str(wf.fold_rmse(f,i)) + "," + ..
                    safe_str(wf.fold_mae(f,i)) + "," + safe_str(wf.fold_mape(f,i)) + "," + safe_str(wf.fold_dir(f,i)));
            end
        end
        p = unique_path(base + "_walkforward.csv"); write_lines(p, L); written = [written; p];
    end

    if typeof(rep.bt) == "st" then
        bt = rep.bt;
        L = "Day,Date,Actual_Close,Strategy_Value,BuyHold_Value,Position_Held";
        for i = 1:size(bt.strategy_value, 1)
            L = append_line(L, string(i) + "," + rep.data.dates(r.test_idx(i)) + "," + safe_str(r.y_true(i)) + "," + ..
                safe_str(bt.strategy_value(i)) + "," + safe_str(bt.buyhold_value(i)) + "," + string(bt.position(i)));
        end
        p = unique_path(base + "_backtest.csv"); write_lines(p, L); written = [written; p];
    end
endfunction


function a = assumptions_struct(data, dq, cfg)
    // Inputs for format_assumptions() from the dataset, its quality summary
    // and the strategy settings in cfg.
    a = struct("capital", cfg.capital, "cost", cfg.cost, "slip", cfg.slip, "buy", cfg.buy, ..
               "sell", cfg.sell, "split_ratio", cfg.split_ratio, "n", data.n, ..
               "train_first", data.dates(1), "train_last", dq.train_last, ..
               "test_first", dq.test_first, "test_last", data.dates($), ..
               "train_rows", dq.train_rows, "test_rows", dq.test_rows);
endfunction


function rep = build_report_struct(label, data, cfg, model_key, with_backtest)
    // Runs the whole pipeline headlessly (all models, walk-forward, optional
    // backtest) and returns the struct the export functions consume.
    dq = data_quality_summary(data, cfg.split_ratio);
    cmp = compare_models(data, cfg.split_ratio, cfg.ar_lookback, cfg.es_alpha, cfg.es_beta, cfg.n_folds);
    keys = ["LR", "AR", "ES"];
    r = cmp.results(find(keys == model_key) + 1);
    sig = generate_signal(data.close($), r.next_price, cfg.buy, cfg.sell);
    sig.current_price = data.close($); sig.buy_thr = cfg.buy; sig.sell_thr = cfg.sell;
    bt = [];
    if with_backtest then
        bt = run_backtest(r.y_true, r.y_pred, cfg.buy, cfg.sell, cfg.capital, cfg.cost, cfg.slip);
    end
    rep = struct("dataset_label", label, "data", data, "dq", dq, "cfg", cfg, "analysis", r, ..
                 "naive", cmp.results(1), "signal", sig, "validated", %t, "cmp", cmp, ..
                 "bt", bt, "assump", assumptions_struct(data, dq, cfg));
endfunction
