// ============================================================================
// model_engine.sce
// -----------------------------------------------------------------------
// All the "brains" of the application, deliberately kept 100% free of any
// GUI code (no uicontrol, no figure, no callbacks). Every function here
// takes plain data in and returns plain data out, which means:
//
//   1. It can be tested headlessly (scilab-cli -nwni), with no display
//      needed at all -- see test_model_engine.sce.
//   2. gui_app.sce's callbacks are thin wrappers that call these functions
//      and push the results into GUI widgets -- the GUI layer never
//      contains any actual modeling logic to get wrong.
//
// Load this file with exec("model_engine.sce", -1) before using it.
//
// -----------------------------------------------------------------------
// REVISION NOTE (fixes applied in this version):
//   - load_dataset() now validates headers, dates, OHLC sanity, volume,
//     minimum length, missing data, and chronological order instead of
//     blindly trusting the file (auto-corrects what it safely can, errors
//     clearly on what it can't).
//   - fit_linear_regression()/fit_ar_model() compute scaling parameters
//     (mu/sigma, price_min/price_max) from the TRAINING split only --
//     previously computed from the whole dataset, which leaked test-period
//     distribution information into the model before evaluation.
//   - predict_next_lr() now uses the true most-recent calendar row's
//     features (today's own OHLCV/MA/lag values), not the last row of the
//     NaN-filtered training array -- which was actually yesterday's row,
//     because the row whose *target* is unknown (today) always got dropped.
//   - Both fit functions solve the least-squares problem via Scilab's
//     backslash directly (X \ y) instead of forming and inverting the
//     normal equations (X'X)\(X'y) by hand -- more numerically stable when
//     features are highly correlated.
//   - MAPE and R^2 guard against division by zero (a zero actual price, or
//     a constant test-target series) instead of silently producing NaN/Inf.
//   - AR's price_max-price_min scaling guards against an all-identical
//     training price series.
//   - moving_average() can now be given the preceding history so the first
//     (window-1) points of a test-period overlay don't have to be blank.
//   - run_backtest() enforces an explicit one-day execution lag between a
//     signal and the return it's allowed to capture, supports transaction
//     costs/slippage, and reports max drawdown, Sharpe ratio, volatility,
//     and a per-trade win rate.
//   - walk_forward_validate() adds a multi-fold, leakage-safe evaluation
//     instead of relying on a single chronological split.
//
// REVISION NOTE (this version): added a THIRD model, Exponential Smoothing
// (Holt's linear trend method) -- fit_exponential_smoothing() /
// evaluate_es_model() / predict_next_es() / walk_forward_validate_es() --
// so the app compares three genuinely different modeling approaches
// (feature-based regression, fixed-window autoregression, and running
// level/trend smoothing) instead of two. See the comment above
// holt_recursion() for how it works and why its fold-evaluation is
// deliberately structured differently from LR/AR's.
// ============================================================================


// ---------------------------------------------------------------------------
// Small validation helpers (no external dependencies -- load_dataset() hands
// these raw strings straight from the file, and they decide what's safe to
// trust before any numeric conversion happens).
// ---------------------------------------------------------------------------
function ok = is_valid_number_string(s)
    // Accepts optional leading +/-, digits, and at most one decimal point.
    // Deliberately does NOT accept scientific notation or thousands
    // separators -- rejecting an ambiguous cell is safer than silently
    // mis-parsing it.
    //
    // Digit-checking is done via ascii() -- converting each character to
    // its numeric ASCII code and comparing THAT with >=/<= -- rather than
    // comparing the characters as strings directly (c >= "0" & c <= "9").
    // Ordering comparisons (>=, <=, >, <) are apparently NOT a defined
    // operation between two Scilab strings (only equality/inequality,
    // == and <>, are) -- confirmed by an actual runtime error report
    // (Scilab's own "Undefined operation... check or define function
    // %c_4_c for overloading", %c being the string type). Comparing
    // ordinary numbers, which >=/<= are unambiguously defined for, sidesteps
    // the question entirely.
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
    // Real calendar check (leap years included) -- rejects e.g. Feb 30th.
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
    // Strict YYYY-MM-DD parsing. No locale/timezone handling on purpose --
    // this app only ever needs day-level ordering of a price series.
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
    // Splits a single line on commas into a 1xN string row vector.
    // Deliberately scans character by character with only part() and a
    // single-character == comparison -- no reliance on any higher-level
    // string-search function's exact behavior on an empty string or a
    // no-match result, none of which can be verified without a live
    // Scilab session.
    //
    // Two passes on purpose: the first just COUNTS commas, so the result
    // can be preallocated as a proper NxN STRING row via repmat("", ...)
    // -- the same preallocation pattern already used successfully for
    // dates_kept/table_rows elsewhere in this codebase -- and then filled
    // in by index. This avoids growing the result from an untyped empty
    // [] via concatenation entirely, so there is no question at all about
    // what type/orientation an empty starting matrix resolves to; the
    // result is a guaranteed 1x(n_commas+1) string matrix from the moment
    // it is first created.
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


// ---------------------------------------------------------------------------
// Data loading + validation
// ---------------------------------------------------------------------------
function data = load_dataset_impl(csv_path)
    // Loads a CSV expected to have the header Date,Open,High,Low,Close,Volume
    // and returns a struct: data.dates (string), data.open/high/low/close/
    // volume (column vectors), data.n (row count), data.warnings (string
    // array of non-fatal issues that were auto-corrected, possibly empty).
    //
    // Fatal problems (wrong columns, no usable rows, too few usable rows,
    // duplicate dates) raise a Scilab error() with a message meant to be
    // shown directly to the user. Non-fatal problems (a handful of bad or
    // missing rows, a file that isn't in chronological order) are cleaned
    // up automatically and reported via data.warnings rather than blocking
    // the user outright.
    //
    // Deliberately reads the file with mgetl() (one raw text line per
    // element, always a plain string, no type auto-detection at all) and
    // splits each line by hand via split_csv_line(), rather than csvRead()
    // -- csvRead tries to auto-detect a numeric vs. string type per column,
    // and a Date column full of "2024-01-01"-style values sitting next to
    // purely numeric OHLCV columns is exactly the kind of mixed content
    // that auto-detection can get wrong in ways that are hard to predict
    // without a live Scilab session to check against. mgetl+split gives up
    // that "convenience" entirely in exchange for full, explicit control:
    // every field really is just a plain string here, always, with no
    // ambiguity about what type csvRead decided to hand back.
    MIN_ROWS_LOAD = 30;   // generous floor: comfortably covers LR's MA10/lag3
                           // warm-up + AR's lookback for any lookback <=15
                           // and any split ratio in the GUI's 50%-95% range.

    if ~isfile(csv_path) then
        error("CSV error: file not found -- [" + csv_path + "].");
    end

    all_lines = mgetl(csv_path);
    if size(all_lines, 1) == 0 then
        error("CSV error: [" + csv_path + "] is empty.");
    end

    // Defensively strip a trailing carriage return from Windows/Excel-style
    // CRLF line endings -- mgetl splits on the line-feed but can leave a
    // trailing \r on each line, which would otherwise corrupt the last
    // field of every row (e.g. "Volume\r" failing to match "Volume", or
    // "1000\r" failing numeric validation). Written as a nested if (not a
    // single "length(li) > 0 & part(li, length(li)) == CR" condition) so
    // the length check is guaranteed to run first no matter how Scilab's
    // & operator handles evaluation order -- indexing an empty string with
    // part(li, length(li)) when length(li) is 0 must never be reachable.
    CR = ascii(13);
    for i = 1:size(all_lines, 1)
        li = all_lines(i);
        if length(li) > 0 then
            if part(li, length(li)) == CR then
                all_lines(i) = part(li, 1:length(li)-1);
            end
        end
    end

    // Drop trailing blank line(s), common at end-of-file. Written with an
    // explicit loop-control flag and an if/elseif/else chain (not a single
    // "size(...) > 0 & stripblanks(all_lines($)) == ..." while-condition),
    // for the same reason as above -- all_lines($) must never be evaluated
    // when all_lines is already empty.
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

    n_raw = size(all_lines, 1) - 1;   // exclude header

    warnings = repmat("", 0, 1);   // explicitly string-typed from the start (0 rows,
                                    // grows via [warnings; "text"] below), not an
                                    // untyped [] -- same repmat("", ...) pattern
                                    // already used for dates_kept/table_rows elsewhere
    n_bad_numeric = 0; n_bad_date = 0; n_bad_ohlc = 0; n_bad_volume = 0; n_blank = 0;
    n_bad_fieldcount = 0;

    // Preallocated (upper-bound-sized) column vectors, filled by an explicit
    // running counter `k` and truncated at the end -- deliberately NOT using
    // dynamic ($+1)-from-empty growth here, since that leaves the resulting
    // row/column orientation ambiguous, and every array below gets
    // horizontally concatenated together later (X_raw_all = [data.open,
    // data.high, ...]), which requires them to all be true Nx1 columns.
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

        // Low <= {Open,Close} <= High by definition of a daily OHLC bar,
        // and all prices must be strictly positive.
        if l <= 0 | h <= 0 | o <= 0 | c <= 0 | h < l - EPS | o < l - EPS | ..
           o > h + EPS | c < l - EPS | c > h + EPS then
            n_bad_ohlc = n_bad_ohlc + 1;
            continue
        end

        k = k + 1;
        dates_kept(k) = row(1);
        open_kept(k) = o; high_kept(k) = h; low_kept(k) = l;
        close_kept(k) = c; volume_kept(k) = v;
        serial_kept(k) = y*372 + m*31 + d;   // monotonic day ordering, not a real Julian day
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
        detail = part(detail, 1:length(detail)-2);   // trim trailing ", "
        warnings = [warnings; "Dropped " + string(n_dropped) + " of " + string(n_raw) + ..
                    " rows (" + detail + ")."];
    end

    // Duplicate dates can't be safely auto-corrected -- fatal.
    [sorted_serial, sort_idx] = gsort(serial_kept, "g", "i");
    for i = 2:n_kept
        if sorted_serial(i) == sorted_serial(i-1) then
            error("CSV error: duplicate date [" + dates_kept(sort_idx(i)) + "] found in [" + ..
                  csv_path + "]. Every row must have a unique date.");
        end
    end

    // Chronological order: auto-sort ascending rather than reject, so
    // newest-first exports (and simply-unsorted files) still load.
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
endfunction


function data = load_dataset(csv_path)
    // Thin defensive wrapper around load_dataset_impl(). All of that
    // function's OWN, anticipated validation failures (bad header, bad
    // dates, too few rows, etc.) already raise clear, friendly error()
    // messages on their own and pass straight through here unchanged.
    // This wrapper exists for the OTHER case: some genuinely unexpected
    // internal error (a Scilab type-mismatch, an indexing slip, or
    // anything else not already anticipated) that would otherwise surface
    // as a bare, cryptic internal error code with no indication of which
    // file or which stage of loading triggered it. Catching it here and
    // re-throwing with that context attached turns "unhelpful internal
    // error" into "a specific file failed at a specific stage, and here is
    // Scilab's own underlying message" -- both for the on-screen popup and
    // for anyone reporting the bug back.
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


// ---------------------------------------------------------------------------
// Linear Regression: feature engineering + fit + evaluate + predict
// ---------------------------------------------------------------------------
function feat = build_lr_features(data)
    // Builds lag1-3, MA5, MA10, 5-day volatility, 1-day return, and the
    // next-day target from data.close, exactly as before -- but now also
    // exposes feat.latest_raw, the TRUE most recent day's own feature row,
    // for use by predict_next_lr() (see that function for why this matters).
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
    feat.n_valid = size(feat.X_raw, 1);
    feat.feature_names = ["Open","High","Low","Close","Volume", ..
                           "Return_1d","MA_5","MA_10","Volatility_5","Lag_1","Lag_2","Lag_3"];

    // Row n (today) always has target = NaN (tomorrow's close is unknown),
    // so it's always excluded from X_raw_all/feat.y above -- correctly, for
    // training. But its OWN features (today's OHLCV, MAs, lags) are fully
    // known today, and are exactly what a real next-day forecast should
    // use. Expose them separately so predict_next_lr() doesn't end up
    // silently using yesterday's row instead.
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


function model = fit_linear_regression(feat, split_ratio)
    // Fits via least-squares on standardized features, chronological
    // train/test split. Scaling parameters (mu/sigma) and the fit itself
    // use ONLY the training rows.
    n_valid = feat.n_valid;
    split_idx = round(n_valid * split_ratio);
    if split_idx < 1 | split_idx >= n_valid then
        error("fit_linear_regression: train/test split leaves an empty side (" + ..
              string(split_idx) + " train / " + string(n_valid - split_idx) + ..
              " test rows) -- adjust the split slider.");
    end

    X_train_raw = feat.X_raw(1:split_idx, :);
    y_train = feat.y(1:split_idx);
    X_test_raw = feat.X_raw(split_idx+1:$, :);
    y_test = feat.y(split_idx+1:$);

    // Scaling parameters come from TRAINING data only -- computing them
    // over the whole dataset (as before) leaks test-period distribution
    // information into the model before it's ever evaluated.
    mu = mean(X_train_raw, "r");
    sigma = stdev(X_train_raw, "r");
    sigma(sigma == 0) = 1;

    n_train = split_idx; n_test = n_valid - split_idx;
    X_train = (X_train_raw - repmat(mu, n_train, 1)) ./ repmat(sigma, n_train, 1);
    X_test  = (X_test_raw  - repmat(mu, n_test, 1))  ./ repmat(sigma, n_test, 1);

    X_train_aug = [ones(n_train, 1), X_train];
    // Least-squares via Scilab's backslash directly on the (overdetermined)
    // design matrix, rather than forming and inverting the normal equations
    // (X'X)\(X'y) by hand -- numerically more stable when features are
    // highly correlated, which OHLC/MA/lag features of one price series
    // always are.
    beta = X_train_aug \ y_train;

    model = struct();
    model.beta = beta; model.mu = mu; model.sigma = sigma;
    model.X_test = X_test; model.y_test = y_test;
    model.split_idx = split_idx;
    model.latest_raw = feat.latest_raw;   // for predict_next_lr

    train_pred = X_train_aug * beta;
    model.train_residual_std = stdev(y_train - train_pred);
endfunction


function ev = evaluate_model(model)
    // Works for both LR and AR models -- both store X_test/y_test/beta in
    // the same shape (an intercept-augmented linear predictor).
    X_test_aug = [ones(size(model.X_test,1),1), model.X_test];
    y_pred = X_test_aug * model.beta;
    residuals = model.y_test - y_pred;

    ev = struct();
    ev.rmse = sqrt(mean(residuals.^2));
    ev.mae = mean(abs(residuals));

    mape_mask = abs(model.y_test) > 1e-8;
    if or(mape_mask) then
        ev.mape = mean(abs(residuals(mape_mask) ./ model.y_test(mape_mask))) * 100;
    else
        ev.mape = %nan;   // every test-period actual price is ~0 -- % error is undefined
    end

    ss_res = sum(residuals.^2);
    ss_tot = sum((model.y_test - mean(model.y_test)).^2);
    if ss_tot > 1e-12 then
        ev.r2 = 1 - ss_res / ss_tot;
    elseif ss_res < 1e-12 then
        ev.r2 = 1;      // test target is a single repeated value and the model hit it exactly
    else
        ev.r2 = %nan;    // test target is a single repeated value -- R^2 is undefined
    end
    ev.y_pred = y_pred;

    // "Prediction Accuracy" -- a simple, GUI-friendly companion to MAPE
    // (100% minus the average percentage error, floored at 0 rather than
    // going negative when the model is worse than a naive guess).
    if isnan(ev.mape) then
        ev.accuracy_pct = %nan;
    else
        ev.accuracy_pct = max(0, 100 - ev.mape);
    end
endfunction


function [next_price, ci_low, ci_high] = predict_next_lr(model)
    // Forecasts tomorrow's close from TODAY's own, fully-known feature row
    // (model.latest_raw) -- not the last row of the training array, which
    // is actually yesterday's row once you account for the target shift
    // (see build_lr_features). Also returns a rough +/-95% uncertainty band
    // from the training residual spread (a normal approximation, not a
    // rigorous prediction interval, but far better than a bare point
    // estimate).
    latest_scaled = (model.latest_raw - model.mu) ./ model.sigma;
    latest_aug = [1, latest_scaled];
    next_price = latest_aug * model.beta;

    margin = 1.96 * model.train_residual_std;
    ci_low = next_price - margin;
    ci_high = next_price + margin;
endfunction


// ---------------------------------------------------------------------------
// AR(p) time-series model. NOTE: this is a LINEAR autoregressive model --
// it is not an LSTM and should never be presented as one. It captures the
// same "look at a rolling window of past values" idea an LSTM's input
// window does, using ordinary least squares instead of a gated recurrent
// network -- linear, not sequential/nonlinear like an actual LSTM.
// ---------------------------------------------------------------------------
function model = fit_ar_model(data, p, split_ratio)
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

    X_raw = zeros(n_samples, p);
    y = zeros(n_samples, 1);
    for i = 1:n_samples
        X_raw(i, :) = close(i:i+p-1)';
        y(i) = close(i+p);
    end

    split_idx = round(n_samples * split_ratio);
    if split_idx < 1 | split_idx >= n_samples then
        error("fit_ar_model: train/test split leaves an empty side -- adjust the split slider.");
    end

    X_train_raw = X_raw(1:split_idx, :); y_train_raw = y(1:split_idx);
    X_test_raw  = X_raw(split_idx+1:$, :); y_test_raw  = y(split_idx+1:$);

    // Scaling range comes from TRAINING data only -- previously computed
    // over the entire close series (including the still-unseen test
    // period), which is data leakage.
    price_min = min([X_train_raw(:); y_train_raw]);
    price_max = max([X_train_raw(:); y_train_raw]);
    price_range = price_max - price_min;
    if price_range < 1e-8 then
        price_range = 1;   // degenerate case: every training price is identical
    end

    X_train = (X_train_raw - price_min) / price_range;
    y_train = (y_train_raw - price_min) / price_range;
    X_test  = (X_test_raw  - price_min) / price_range;
    y_test  = (y_test_raw  - price_min) / price_range;

    X_train_aug = [ones(size(X_train,1),1), X_train];
    beta = X_train_aug \ y_train;   // least-squares backslash -- see fit_linear_regression

    model = struct();
    model.beta = beta; model.p = p; model.split_idx = split_idx;
    model.price_min = price_min; model.price_max = price_min + price_range;
    model.X_test = X_test; model.y_test = y_test;
    model.y_train_real = y_train_raw;   // for the MA-overlay history fix in the GUI

    latest_window = (close($-p+1:$)' - price_min) / price_range;
    model.X_scaled_last_row = latest_window;

    train_pred_scaled = X_train_aug * beta;
    resid_scaled = y_train - train_pred_scaled;
    model.train_residual_std = stdev(resid_scaled) * price_range;   // back to real price units
endfunction


function ev = evaluate_ar_model(model)
    // AR model works in scaled [0,1] space -- convert back to real price
    // units before computing metrics, same as evaluate_model() does for LR.
    X_test_aug = [ones(size(model.X_test,1),1), model.X_test];
    y_pred_scaled = X_test_aug * model.beta;

    y_test_real = model.y_test * (model.price_max - model.price_min) + model.price_min;
    y_pred_real = y_pred_scaled * (model.price_max - model.price_min) + model.price_min;
    residuals = y_test_real - y_pred_real;

    ev = struct();
    ev.rmse = sqrt(mean(residuals.^2));
    ev.mae = mean(abs(residuals));

    mape_mask = abs(y_test_real) > 1e-8;
    if or(mape_mask) then
        ev.mape = mean(abs(residuals(mape_mask) ./ y_test_real(mape_mask))) * 100;
    else
        ev.mape = %nan;
    end

    ss_res = sum(residuals.^2);
    ss_tot = sum((y_test_real - mean(y_test_real)).^2);
    if ss_tot > 1e-12 then
        ev.r2 = 1 - ss_res / ss_tot;
    elseif ss_res < 1e-12 then
        ev.r2 = 1;
    else
        ev.r2 = %nan;
    end
    ev.y_pred = y_pred_real;
    ev.y_test_real = y_test_real;

    if isnan(ev.mape) then
        ev.accuracy_pct = %nan;
    else
        ev.accuracy_pct = max(0, 100 - ev.mape);
    end
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
// Exponential Smoothing (Holt's linear trend method) -- a third, genuinely
// different modeling approach alongside Linear Regression (feature-based)
// and AR (fixed-window autoregression). Holt's method carries forward a
// single running LEVEL and TREND estimate, updated day by day as new
// prices arrive, and forecasts one step ahead as level + trend. Unlike
// LR/AR there is no feature matrix and nothing solved via least-squares;
// alpha (level smoothing) and beta (trend smoothing) are fixed
// hyperparameters supplied by the caller (see ES_ALPHA/ES_BETA in
// gui_app.sce), not fit from data -- so there is no train/test leakage
// risk in the parameter-estimation sense the REVISION NOTE above
// describes fixing for LR/AR.
//
// What IS deliberately different from LR/AR here: this model's state is
// built with ONE continuous recursion across the whole series (training
// period followed by test period) rather than an independent from-scratch
// refit on just the training slice. That is not an oversight -- throwing
// away the running level/trend at the train/test boundary and restarting
// cold from the first test-period price would discard exactly the
// sequential memory that makes this a time-series model in the first
// place. Every forecast used for evaluation is still a genuine one-step-
// AHEAD forecast, computed from state built only out of days strictly
// before it -- the test period is never peeked at early.
// ---------------------------------------------------------------------------
function [L, T, fcst] = holt_recursion(close, alpha, beta)
    // close: Nx1 vector, N >= 2. Returns:
    //   L, T  : Nx1 running level/trend estimates (L(1)/T(1) are the
    //           initial seed, not yet informed by any forecast error)
    //   fcst  : Nx1, with fcst(1) = %nan (no prior state to forecast
    //           from yet) and fcst(t) for t>=2 = the one-step-ahead
    //           forecast for close(t), computed from L(t-1)/T(t-1)
    //           BEFORE close(t) is used to update the state.
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


function model = fit_exponential_smoothing(data, split_ratio, alpha, beta)
    if alpha <= 0 | alpha > 1 | beta < 0 | beta > 1 then
        error("fit_exponential_smoothing: alpha must be in (0,1] and beta in [0,1] " + ..
              "(got alpha=" + string(alpha) + ", beta=" + string(beta) + ").");
    end
    close = data.close;
    n = data.n;
    if n < 10 then
        error("fit_exponential_smoothing: need at least 10 rows (got " + string(n) + ").");
    end
    split_idx = round(n * split_ratio);
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
    model.train_residual_std = stdev(train_actual - train_pred);
    model.final_level = L(n); model.final_trend = T(n);
endfunction


function ev = evaluate_es_model(model)
    // Same metric definitions as evaluate_model()/evaluate_ar_model() --
    // see those for the MAPE/R^2 zero-guard rationale, not repeated here.
    residuals = model.y_test - model.y_pred;
    ev = struct();
    ev.rmse = sqrt(mean(residuals.^2));
    ev.mae = mean(abs(residuals));

    mape_mask = abs(model.y_test) > 1e-8;
    if or(mape_mask) then
        ev.mape = mean(abs(residuals(mape_mask) ./ model.y_test(mape_mask))) * 100;
    else
        ev.mape = %nan;
    end

    ss_res = sum(residuals.^2);
    ss_tot = sum((model.y_test - mean(model.y_test)).^2);
    if ss_tot > 1e-12 then
        ev.r2 = 1 - ss_res / ss_tot;
    elseif ss_res < 1e-12 then
        ev.r2 = 1;
    else
        ev.r2 = %nan;
    end
    ev.y_pred = model.y_pred;

    if isnan(ev.mape) then
        ev.accuracy_pct = %nan;
    else
        ev.accuracy_pct = max(0, 100 - ev.mape);
    end
endfunction


function [next_price, ci_low, ci_high] = predict_next_es(model)
    // Tomorrow's forecast is simply the final running level plus the final
    // running trend -- the whole point of Holt's method is that this
    // state is already up to date with every price through today.
    next_price = model.final_level + model.final_trend;
    margin = 1.96 * model.train_residual_std;
    ci_low = next_price - margin;
    ci_high = next_price + margin;
endfunction


function results = walk_forward_validate_es(data, n_folds, alpha, beta)
    // Fold windows (min_train / fold_size / remainder-absorption) computed
    // identically to walk_forward_validate() for comparability -- but
    // evaluated as slices of ONE continuous Holt recursion over the whole
    // series, not independent refits per fold. See the comment above
    // holt_recursion() for why that is the correct choice for this model.
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

        yte = close(train_end+1:test_end);
        pred = fcst(train_end+1:test_end);
        resid = yte - pred;

        fold_rmse(f) = sqrt(mean(resid.^2));
        fold_mae(f) = mean(abs(resid));

        mask = abs(yte) > 1e-8;
        if or(mask) then
            fold_mape(f) = mean(abs(resid(mask) ./ yte(mask))) * 100;
        else
            fold_mape(f) = %nan;
        end

        ss_tot = sum((yte - mean(yte)).^2);
        if ss_tot > 1e-12 then
            fold_r2(f) = 1 - sum(resid.^2) / ss_tot;
        else
            fold_r2(f) = %nan;
        end
    end

    results = struct();
    results.fold_rmse = fold_rmse; results.fold_mae = fold_mae;
    results.fold_mape = fold_mape; results.fold_r2 = fold_r2;
    results.fold_train_end = fold_train_end; results.fold_test_end = fold_test_end;
    results.n_total = n; results.min_train = min_train;
    results.mean_rmse = mean(fold_rmse); results.mean_mae = mean(fold_mae);
    valid_mape = fold_mape(~isnan(fold_mape));
    if size(valid_mape, 1) > 0 then results.mean_mape = mean(valid_mape); else results.mean_mape = %nan; end
    valid_r2 = fold_r2(~isnan(fold_r2));
    if size(valid_r2, 1) > 0 then results.mean_r2 = mean(valid_r2); else results.mean_r2 = %nan; end
    results.n_folds = n_folds;
endfunction


// ---------------------------------------------------------------------------
// Walk-forward validation -- a more convincing time-series evaluation than
// a single chronological split: splits the usable data into n_folds
// sequential, expanding-window folds (train on everything before the fold,
// test only on the fold itself), refitting scaling parameters from each
// fold's own training portion so no fold leaks into another.
// ---------------------------------------------------------------------------
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
        if f == n_folds then test_end = n; end   // last fold absorbs any remainder
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
        resid = yte - pred;

        fold_rmse(f) = sqrt(mean(resid.^2));
        fold_mae(f) = mean(abs(resid));

        mask = abs(yte) > 1e-8;
        if or(mask) then
            fold_mape(f) = mean(abs(resid(mask) ./ yte(mask))) * 100;
        else
            fold_mape(f) = %nan;
        end

        ss_tot = sum((yte - mean(yte)).^2);
        if ss_tot > 1e-12 then
            fold_r2(f) = 1 - sum(resid.^2) / ss_tot;
        else
            fold_r2(f) = %nan;
        end
    end

    results = struct();
    results.fold_rmse = fold_rmse; results.fold_mae = fold_mae;
    results.fold_mape = fold_mape; results.fold_r2 = fold_r2;
    results.fold_train_end = fold_train_end; results.fold_test_end = fold_test_end;
    results.n_total = n; results.min_train = min_train;
    results.mean_rmse = mean(fold_rmse); results.mean_mae = mean(fold_mae);
    valid_mape = fold_mape(~isnan(fold_mape));
    if size(valid_mape, 1) > 0 then results.mean_mape = mean(valid_mape); else results.mean_mape = %nan; end
    valid_r2 = fold_r2(~isnan(fold_r2));
    if size(valid_r2, 1) > 0 then results.mean_r2 = mean(valid_r2); else results.mean_r2 = %nan; end
    results.n_folds = n_folds;
endfunction


// ---------------------------------------------------------------------------
// Signal generation (same threshold rule used across every part of this
// whole body of work). NOTE: "SELL" means exit an existing long position --
// this app has no short-selling state; it is only ever long or in cash.
// ---------------------------------------------------------------------------
function signal = generate_signal(current_price, predicted_price, buy_threshold, sell_threshold)
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


// ---------------------------------------------------------------------------
// Simple moving average helper (used by the "show moving average" overlay)
// ---------------------------------------------------------------------------
function ma = moving_average(series, window, history)
    // Computes a trailing moving average over `series`. If `history` (the
    // values immediately preceding series -- e.g. the training-period
    // prices right before a test period) is supplied, it's used to fill in
    // the first (window-1) points too, instead of leaving them NaN just
    // because `series` itself doesn't have window-1 points of run-up yet.
    // Omitting `history` reproduces the original NaN-padded behavior.
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


// ---------------------------------------------------------------------------
// Backtest simulator -- walks through the given period day by day, deciding
// BUY/SELL/HOLD the same way generate_signal() does, and tracks what a
// starting sum of money would actually have become, compared against a
// simple buy-and-hold baseline on the same period.
//
// EXECUTION LAG (structural, not just documented): a signal computed at
// index i is applied starting at index i+1's return onward -- it can never
// affect the return already realized by index i itself. This is enforced
// directly by the loop's ordering (today's return is booked BEFORE today's
// signal is computed), rather than relying on an upstream array's shifted
// indexing to happen to line up correctly.
//
// transaction_cost_pct and slippage_pct (percent, e.g. 0.1 for 0.1%) are
// deducted from the portfolio whenever a trade actually executes. Both
// default to 0, matching the original zero-cost, perfect-execution
// behavior, so existing callers don't have to change.
// ---------------------------------------------------------------------------
function bt = run_backtest(y_actual, y_pred, buy_threshold, sell_threshold, starting_capital, ..
                            transaction_cost_pct, slippage_pct)
    if argn(2) < 7 then slippage_pct = 0; end
    if argn(2) < 6 then transaction_cost_pct = 0; end

    // y_actual feeds a multiplicative chain (strategy_value(i) depends on
    // strategy_value(i-1)) -- a single NaN or non-positive entry (e.g. an
    // uncleaned data gap) would silently corrupt every subsequent day
    // rather than staying local to that one row, so this is checked
    // up front with a clear error instead of quietly propagating garbage.
    // y_pred is NOT checked this strictly: a NaN prediction for one day
    // just fails both the buy and sell threshold comparisons and safely
    // falls through to HOLD for that day only (no crash, no propagation).
    if or(isnan(y_actual)) | or(y_actual <= 0) then
        error("run_backtest: y_actual contains a NaN or non-positive price -- clean the data " + ..
              "(e.g. via load_dataset()) before backtesting.");
    end

    cost_frac = (transaction_cost_pct + slippage_pct) / 100;

    n = size(y_actual, 1);
    strategy_value = zeros(n, 1);
    buyhold_value = zeros(n, 1);
    in_position = %f;
    n_trades = 0;
    entry_price = %nan;
    trade_returns = [];

    strategy_value(1) = starting_capital;
    buyhold_value(1) = starting_capital;

    for i = 2:n
        day_return = (y_actual(i) - y_actual(i-1)) / y_actual(i-1);

        // Realize today's return using whatever position was already held
        // coming INTO today (decided on a prior iteration, never this one).
        if in_position then
            strategy_value(i) = strategy_value(i-1) * (1 + day_return);
        else
            strategy_value(i) = strategy_value(i-1);
        end
        buyhold_value(i) = buyhold_value(i-1) * (1 + day_return);   // always invested

        // NOW decide today's signal -- this can only affect NEXT iteration's
        // return, never the one just booked above.
        prev_price = y_actual(i-1);
        pred_price = y_pred(i);
        pct = (pred_price - prev_price) / prev_price * 100;
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
            entry_price = y_actual(i);
        elseif action == "SELL" & in_position then
            strategy_value(i) = strategy_value(i) * (1 - cost_frac);
            in_position = %f;
            n_trades = n_trades + 1;
            trade_returns = [trade_returns; (y_actual(i) - entry_price) / entry_price];
        end
    end

    // --- risk-adjusted metrics (computed on the strategy's own daily returns) ---
    daily_returns = zeros(max(n-1, 0), 1);
    for i = 2:n
        daily_returns(i-1) = (strategy_value(i) - strategy_value(i-1)) / strategy_value(i-1);
    end

    running_peak = strategy_value(1);
    max_drawdown_pct = 0;
    for i = 1:n
        if strategy_value(i) > running_peak then running_peak = strategy_value(i); end
        dd = (running_peak - strategy_value(i)) / running_peak * 100;
        if dd > max_drawdown_pct then max_drawdown_pct = dd; end
    end

    sharpe_ratio = %nan;
    volatility_pct_annualized = %nan;
    n_dr = size(daily_returns, 1);
    if n_dr >= 2 then
        dr_std = stdev(daily_returns);
        volatility_pct_annualized = dr_std * sqrt(252) * 100;
        if dr_std > 1e-12 then
            sharpe_ratio = mean(daily_returns) / dr_std * sqrt(252);
        end
    end

    n_completed_trades = size(trade_returns, 1);
    if n_completed_trades > 0 then
        win_rate_pct = sum(trade_returns > 0) / n_completed_trades * 100;
    else
        win_rate_pct = %nan;   // no completed round-trip trades to score
    end

    bt = struct();
    bt.starting_capital = starting_capital;
    bt.strategy_value = strategy_value;
    bt.buyhold_value = buyhold_value;
    bt.n_trades = n_trades;
    bt.strategy_final = strategy_value($);
    bt.buyhold_final = buyhold_value($);
    bt.strategy_return_pct = (strategy_value($) - starting_capital) / starting_capital * 100;
    bt.buyhold_return_pct = (buyhold_value($) - starting_capital) / starting_capital * 100;
    bt.max_drawdown_pct = max_drawdown_pct;
    bt.sharpe_ratio = sharpe_ratio;
    bt.volatility_pct_annualized = volatility_pct_annualized;
    bt.win_rate_pct = win_rate_pct;
    bt.n_completed_trades = n_completed_trades;
    bt.transaction_cost_pct = transaction_cost_pct;
    bt.slippage_pct = slippage_pct;
endfunction
