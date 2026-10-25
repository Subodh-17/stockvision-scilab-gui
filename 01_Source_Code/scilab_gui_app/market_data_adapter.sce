// ============================================================================
// market_data_adapter.sce -- StockVision Market Data Adapter (Twelve Data)
//
// Pure Scilab functions for retrieving, parsing, validating, normalizing,
// and caching real financial market data (US equities, Indian NSE/BSE stocks).
//
// Provider: Twelve Data (https://twelvedata.com)
// Supported markets: US (NASDAQ, NYSE), India (NSE, BSE), and other global exchanges.
// Primary endpoint: /time_series (daily OHLCV interval).
//
// Headless & pure: No GUI dependencies. Can be tested standalone or invoked
// from gui_app.sce callbacks.
//
// Load with: exec("market_data_adapter.sce", -1);
// ============================================================================


// ---------------------------------------------------------------------------
// 1. Path and Directory Helpers
// ---------------------------------------------------------------------------

function p = mda_adapter_dir()
    // Returns the directory containing this script.
    try
        p = get_absolute_file_path("market_data_adapter.sce");
    catch
        p = pwd() + filesep();
    end
endfunction


function p = mda_project_root()
    // Locates the project root (contains config/ or 01_Source_Code/).
    adir = mda_adapter_dir();
    // Check if adir is inside 01_Source_Code/scilab_gui_app
    cand = adir + ".." + filesep() + ".." + filesep();
    if isdir(cand + "config") | isdir(cand + "01_Source_Code") then
        p = cand;
        return;
    end
    cand = pwd() + filesep();
    if isdir(cand + "config") | isdir(cand + "01_Source_Code") then
        p = cand;
        return;
    end
    p = adir;
endfunction


// ---------------------------------------------------------------------------
// 2. Configuration Management
// ---------------------------------------------------------------------------

function cfg = mda_default_config()
    cfg = struct();
    cfg.provider = "twelvedata";
    cfg.api_key = "";
    cfg.cache_enabled = %t;
    cfg.cache_ttl_hours = 4.0;
    cfg.default_outputsize = 120;
    cfg.supported_exchanges = ["NASDAQ", "NYSE", "NSE", "BSE"];
    cfg.attribution = "Data provided by Twelve Data (twelvedata.com)";
    cfg.base_url = "https://api.twelvedata.com";
endfunction


function cfg = mda_load_config(custom_path)
    // Loads configuration from JSON file or environment variables.
    cfg = mda_default_config();

    config_path = "";
    if argn(2) >= 1 & custom_path <> "" then
        if isfile(custom_path) then config_path = custom_path; end
    end
    if config_path == "" then
        root = mda_project_root();
        cand1 = root + "config" + filesep() + "market_data_config.json";
        cand2 = root + "config" + filesep() + "market_data_config.json.example";
        if isfile(cand1) then
            config_path = cand1;
        elseif isfile(cand2) then
            config_path = cand2;
        end
    end

    if config_path <> "" & isfile(config_path) then
        try
            lines = mgetl(config_path);
            raw = strcat(lines, "");
            parsed = fromJSON(raw);
            if isfield(parsed, "provider") then cfg.provider = parsed.provider; end
            if isfield(parsed, "api_key") then
                // Ignore placeholder text
                if parsed.api_key <> "YOUR_TWELVE_DATA_API_KEY_HERE" then
                    cfg.api_key = parsed.api_key;
                end
            end
            if isfield(parsed, "cache_enabled") then cfg.cache_enabled = parsed.cache_enabled; end
            if isfield(parsed, "cache_ttl_hours") then cfg.cache_ttl_hours = parsed.cache_ttl_hours; end
            if isfield(parsed, "default_outputsize") then cfg.default_outputsize = parsed.default_outputsize; end
            if isfield(parsed, "attribution") then cfg.attribution = parsed.attribution; end
            if isfield(parsed, "base_url") then cfg.base_url = parsed.base_url; end
        catch
            // Fall back to defaults on corrupt config
        end
    end

    // Environment variable overrides file config (for CI/CD or secure terminals)
    env_key = getenv("TWELVE_DATA_API_KEY", "");
    if env_key <> "" then
        cfg.api_key = env_key;
    end
endfunction


// ---------------------------------------------------------------------------
// 3. Local Cache Management
// ---------------------------------------------------------------------------

function cdir = mda_ensure_cache_dir()
    root = mda_project_root();
    cdir = root + "cache" + filesep() + "market_data" + filesep();
    if ~isdir(cdir) then
        try
            mkdir(root + "cache");
            mkdir(cdir);
        catch
            // Fall back to adapter directory if root is read-only
            cdir = mda_adapter_dir() + "cache" + filesep() + "market_data" + filesep();
            mkdir(cdir);
        end
    end
endfunction


function fpath = mda_cache_path(symbol, exchange, outputsize)
    cdir = mda_ensure_cache_dir();
    sym_clean = convstr(stripblanks(symbol), "u");
    exch_clean = convstr(stripblanks(exchange), "u");
    if exch_clean == "" then exch_clean = "AUTO"; end
    fname = sym_clean + "_" + exch_clean + "_" + string(outputsize) + ".json";
    fpath = cdir + fname;
endfunction


function [cached_struct, is_valid] = mda_read_cache(symbol, exchange, outputsize, ttl_hours)
    cached_struct = struct();
    is_valid = %f;
    fpath = mda_cache_path(symbol, exchange, outputsize);
    if ~isfile(fpath) then return; end

    fi = fileinfo(fpath);
    if size(fi, "*") < 6 then return; end
    mtime = fi(6);
    now_sec = getdate("s");
    age_hours = (now_sec - mtime) / 3600.0;
    if age_hours > ttl_hours then return; end

    try
        lines = mgetl(fpath);
        raw = strcat(lines, "");
        cached_struct = fromJSON(raw);
        // If _cache_meta is missing, derive original retrieval time from file modification timestamp
        if ~isfield(cached_struct, "_cache_meta") then
            md = getdate(mtime);
            dt_str = msprintf("%04d-%02d-%02d %02d:%02d:%02d", md(1), md(2), md(6), md(7), md(8), md(9));
            cached_struct._cache_meta = struct("retrieved_at", dt_str, "retrieved_sec", mtime);
        end
        is_valid = %t;
    catch
        is_valid = %f;
    end
endfunction


function ok = mda_write_cache(symbol, exchange, outputsize, payload_struct)
    ok = %f;
    try
        fpath = mda_cache_path(symbol, exchange, outputsize);
        // Attach cache provenance metadata distinguishing retrieval time from future access
        payload_struct._cache_meta = struct("retrieved_at", mda_current_iso_time(), ..
                                            "retrieved_sec", getdate("s"), ..
                                            "symbol", symbol, ..
                                            "exchange", exchange, ..
                                            "outputsize", outputsize);
        json_str = toJSON(payload_struct);
        mputl(json_str, fpath);
        ok = %t;
    catch
        ok = %f;
    end
endfunction


// ---------------------------------------------------------------------------
// 4. Time and Error Sanitization Helpers
// ---------------------------------------------------------------------------

function s = mda_current_iso_time()
    d = getdate();
    // d = [year, month, week, day_of_year, day_of_week, day, hour, min, sec, msec]
    y = string(d(1));
    m = string(d(2)); if length(m) < 2 then m = "0" + m; end
    day = string(d(6)); if length(day) < 2 then day = "0" + day; end
    h = string(d(7)); if length(h) < 2 then h = "0" + h; end
    minu = string(d(8)); if length(minu) < 2 then minu = "0" + minu; end
    sec = string(d(9)); if length(sec) < 2 then sec = "0" + sec; end
    s = y + "-" + m + "-" + day + " " + h + ":" + minu + ":" + sec;
endfunction


function clean_msg = mda_sanitize_error(err_raw, api_key)
    // Sanitizes error messages by masking API keys and credentials
    // before displaying in user dialogs or writing to reports/logs.
    if typeof(err_raw) <> "string" then
        clean_msg = string(err_raw);
    else
        clean_msg = strcat(err_raw, " ");
    end
    clean_msg = stripblanks(clean_msg);

    // 1. Mask explicit apikey query param pattern if present
    try
        clean_msg = strsubst(clean_msg, "/apikey=[^& \t\r\n]+/", "apikey=***MASKED***", "r");
        clean_msg = strsubst(clean_msg, "/api_key=[^& \t\r\n]+/", "api_key=***MASKED***", "r");
    catch
        // In case regex engine throws on unexpected pattern
    end

    // 2. If api_key is non-empty and non-trivial (length >= 4), strip any raw occurrence
    if argn(2) >= 2 & typeof(api_key) == "string" then
        key_trimmed = stripblanks(api_key);
        if length(key_trimmed) >= 4 & key_trimmed <> "demo" then
            clean_msg = strsubst(clean_msg, key_trimmed, "***MASKED_API_KEY***");
        end
    end
endfunction


// ---------------------------------------------------------------------------
// 5. Response Parsing, Validation, and Engine Normalization
// ---------------------------------------------------------------------------

function data = mda_parse_timeseries_response(res, requested_symbol, requested_exchange, is_cache_hit)
    // Validates a parsed Twelve Data struct response and normalizes it into
    // the exact data schema expected by StockVision's model_engine.sce.
    //
    // Guaranteed invariants:
    // - Output rows are in strictly ASCENDING chronological order (oldest to newest).
    // - Every row has valid ISO YYYY-MM-DD date and numeric OHLCV with Low <= High.
    // - Duplicate dates are detected and rejected.
    // - Returns at least 30 usable bars (minimum for statistical model fitting).
    MIN_ROWS_LOAD = 30;

    if typeof(res) <> "st" then
        error("Market data error: response is not a valid structured object.");
    end

    // Check for provider error payload
    if isfield(res, "status") then
        if convstr(res.status, "l") == "error" then
            code_num = 0;
            if isfield(res, "code") then code_num = res.code; end
            msg_str = "Unknown provider error.";
            if isfield(res, "message") then msg_str = res.message; end

            if code_num == 429 then
                error("Market data rate limit (HTTP 429): " + msg_str + ..
                      " Twelve Data free tier allows 8 API credits/min. Please wait 60s or select an offline synthetic dataset.");
            elseif code_num == 404 | code_num == 400 then
                error("Market data symbol error (HTTP " + string(code_num) + "): " + msg_str + ..
                      " Check ticker symbol [" + requested_symbol + "] and exchange [" + requested_exchange + "].");
            elseif code_num == 401 | code_num == 403 then
                error("Market data authentication error (HTTP " + string(code_num) + "): " + msg_str + ..
                      " Please configure your free API key in config/market_data_config.json or environment variable TWELVE_DATA_API_KEY.");
            else
                error("Market data error (HTTP " + string(code_num) + "): " + msg_str);
            end
        end
    end

    if ~isfield(res, "values") then
        error("Market data error: response payload does not contain a ''values'' array.");
    end

    n_raw = size(res.values, 2);
    if n_raw == 0 then
        error("Market data error: provider returned 0 price observations for [" + ..
              requested_symbol + "]. Verify that the market is open or symbol is active.");
    end

    // Extract metadata
    meta_symbol = requested_symbol;
    meta_exchange = requested_exchange;
    meta_timezone = "UTC";
    meta_currency = "USD";
    if isfield(res, "meta") then
        if isfield(res.meta, "symbol") then meta_symbol = res.meta.symbol; end
        if isfield(res.meta, "exchange") then meta_exchange = res.meta.exchange; end
        if isfield(res.meta, "exchange_timezone") then meta_timezone = res.meta.exchange_timezone; end
        if isfield(res.meta, "currency") then meta_currency = res.meta.currency; end
    end

    // Preallocate storage (raw count)
    dates_raw = repmat("", n_raw, 1);
    open_raw = zeros(n_raw, 1);
    high_raw = zeros(n_raw, 1);
    low_raw = zeros(n_raw, 1);
    close_raw = zeros(n_raw, 1);
    volume_raw = zeros(n_raw, 1);
    serial_raw = zeros(n_raw, 1);

    warnings = repmat("", 0, 1);
    n_bad_numeric = 0; n_bad_date = 0; n_bad_ohlc = 0; n_bad_volume = 0;
    EPS = 1e-6;
    k = 0;

    // Twelve Data returns bars newest-first (res.values(1) is the most recent date).
    // We iterate backwards from n_raw down to 1 so that our raw vectors are chronologically ordered.
    for idx = n_raw:-1:1
        bar = res.values(idx);
        if ~isfield(bar, "datetime") | ~isfield(bar, "open") | ~isfield(bar, "high") | ..
           ~isfield(bar, "low") | ~isfield(bar, "close") | ~isfield(bar, "volume") then
            n_bad_numeric = n_bad_numeric + 1;
            continue;
        end

        dt_str = stripblanks(bar.datetime);
        // If datetime contains time component (e.g. YYYY-MM-DD HH:MM:SS), take YYYY-MM-DD
        if length(dt_str) >= 10 then
            dt_str = part(dt_str, 1:10);
        end

        [y, m, d, date_ok] = parse_iso_date(dt_str);
        if ~date_ok then
            n_bad_date = n_bad_date + 1;
            continue;
        end

        o = strtod(bar.open);
        h = strtod(bar.high);
        l = strtod(bar.low);
        c = strtod(bar.close);
        v = strtod(bar.volume);

        if isnan(o) | isnan(h) | isnan(l) | isnan(c) | isnan(v) then
            n_bad_numeric = n_bad_numeric + 1;
            continue;
        end

        if v < 0 then
            n_bad_volume = n_bad_volume + 1;
            continue;
        end

        // Bar sanity: Low <= {Open, Close} <= High, all prices > 0
        if l <= 0 | h <= 0 | o <= 0 | c <= 0 | h < l - EPS | o < l - EPS | ..
           o > h + EPS | c < l - EPS | c > h + EPS then
            n_bad_ohlc = n_bad_ohlc + 1;
            continue;
        end

        k = k + 1;
        dates_raw(k) = dt_str;
        open_raw(k) = o; high_raw(k) = h; low_raw(k) = l;
        close_raw(k) = c; volume_raw(k) = v;
        serial_raw(k) = y * 372 + m * 31 + d;
    end

    n_kept = k;
    if n_kept == 0 then
        error("Market data error: no usable bars survived validation for [" + requested_symbol + "].");
    end

    dates_kept = dates_raw(1:n_kept);
    open_kept = open_raw(1:n_kept);
    high_kept = high_raw(1:n_kept);
    low_kept = low_raw(1:n_kept);
    close_kept = close_raw(1:n_kept);
    volume_kept = volume_raw(1:n_kept);
    serial_kept = serial_raw(1:n_kept);

    n_dropped = n_raw - n_kept;
    if n_dropped > 0 then
        detail = "";
        if n_bad_date > 0 then detail = detail + string(n_bad_date) + " bad date, "; end
        if n_bad_numeric > 0 then detail = detail + string(n_bad_numeric) + " non-numeric, "; end
        if n_bad_volume > 0 then detail = detail + string(n_bad_volume) + " negative vol, "; end
        if n_bad_ohlc > 0 then detail = detail + string(n_bad_ohlc) + " invalid OHLC, "; end
        detail = part(detail, 1:length(detail)-2);
        warnings = [warnings; "Dropped " + string(n_dropped) + " of " + string(n_raw) + ..
                    " market bars (" + detail + ")."];
    end

    // Verify chronological ordering and uniqueness
    [sorted_serial, sort_idx] = gsort(serial_kept, "g", "i");
    for i = 2:n_kept
        if sorted_serial(i) == sorted_serial(i-1) then
            error("Market data error: duplicate date [" + dates_kept(sort_idx(i)) + ..
                  "] detected in market feed for [" + requested_symbol + "].");
        end
    end

    was_sorted = %t;
    for i = 1:n_kept
        if sort_idx(i) <> i then was_sorted = %f; end
    end
    if ~was_sorted then
        dates_kept = dates_kept(sort_idx); open_kept = open_kept(sort_idx);
        high_kept = high_kept(sort_idx); low_kept = low_kept(sort_idx);
        close_kept = close_kept(sort_idx); volume_kept = volume_kept(sort_idx);
        warnings = [warnings; "Market bars were re-sorted into strict ascending chronological order."];
    end

    if n_kept < MIN_ROWS_LOAD then
        error("Market data error: only " + string(n_kept) + " usable rows retrieved for [" + ..
              requested_symbol + "] -- at least " + string(MIN_ROWS_LOAD) + " rows required. Request larger outputsize.");
    end

    // Anomaly checks
    n_price_jumps = 0; n_zero_vol = 0; n_gaps = 0;
    for i = 2:n_kept
        ret_1d = abs(close_kept(i) - close_kept(i-1)) / close_kept(i-1);
        if ret_1d > 0.50 then n_price_jumps = n_price_jumps + 1; end
        if serial_kept(i) - serial_kept(i-1) > 14 then n_gaps = n_gaps + 1; end
    end
    n_zero_vol = sum(volume_kept == 0);
    n_anomalies = n_price_jumps + n_zero_vol + n_gaps;
    if n_price_jumps > 0 then
        warnings = [warnings; string(n_price_jumps) + " daily return jump(s) >50% detected in market feed."];
    end
    if n_zero_vol > 0 then
        warnings = [warnings; string(n_zero_vol) + " market bar(s) with volume == 0 detected."];
    end
    if n_gaps > 0 then
        warnings = [warnings; string(n_gaps) + " trading date gap(s) (>14 days) detected."];
    end

    // Populate standard quality structure
    q = struct();
    q.raw_rows = n_raw;
    q.rows = n_kept;
    q.dropped = n_dropped;
    q.missing = n_bad_numeric;
    q.bad_dates = n_bad_date;
    q.invalid_ohlc = n_bad_ohlc + n_bad_volume;
    q.duplicates = 0;
    q.was_chronological = was_sorted;
    q.date_first = dates_kept(1);
    q.date_last = dates_kept($);
    q.anomalies_detected = n_anomalies;
    q.price_jumps = n_price_jumps;
    q.zero_volume_bars = n_zero_vol;
    q.date_gaps = n_gaps;

    // Build data structure matching model_engine.sce schema
    data = struct();
    data.dates = dates_kept;
    data.open = open_kept;
    data.high = high_kept;
    data.low = low_kept;
    data.close = close_kept;
    data.volume = volume_kept;
    data.n = n_kept;
    data.warnings = warnings;
    data.quality = q;

    // Attach provider provenance metadata
    data.provider = "Twelve Data";
    data.symbol = meta_symbol;
    data.exchange = meta_exchange;
    data.currency = meta_currency;
    data.timezone = meta_timezone;
    data.attribution = "Data provided by Twelve Data (twelvedata.com)";
    data.source_mode = "LIVE_MARKET";

    if is_cache_hit then
        if isfield(res, "_cache_meta") & isfield(res._cache_meta, "retrieved_at") then
            data.retrieval_time = res._cache_meta.retrieved_at;
        else
            data.retrieval_time = mda_current_iso_time();
        end
        data.cache_access_time = mda_current_iso_time();
        data.data_freshness = "End-of-Day / 15m Delayed [Local Cache Hit]";
    else
        data.retrieval_time = mda_current_iso_time();
        data.cache_access_time = "N/A (Live Network Fetch)";
        data.data_freshness = "End-of-Day / 15m Delayed [Live Network Fetch]";
    end
endfunction


// ---------------------------------------------------------------------------
// 6. Primary Fetch API
// ---------------------------------------------------------------------------

function data = mda_fetch_market_data(symbol, exchange, outputsize, force_refresh, config_override)
    // Primary entry point for acquiring real market data.
    // Handles config loading, local caching, HTTP network fetch, and normalization.
    //
    // Never silently falls back to synthetic data. Errors are raised explicitly.

    symbol = convstr(stripblanks(symbol), "u");
    exchange = convstr(stripblanks(exchange), "u");
    if symbol == "" then
        error("Market data error: symbol cannot be empty.");
    end

    if argn(2) < 3 then outputsize = 120; end
    if argn(2) < 4 then force_refresh = %f; end
    if argn(2) >= 5 & typeof(config_override) == "st" then
        cfg = config_override;
    else
        cfg = mda_load_config();
    end

    // Check local cache first (if not forcing refresh)
    if ~force_refresh & cfg.cache_enabled then
        [cached_res, is_valid] = mda_read_cache(symbol, exchange, outputsize, cfg.cache_ttl_hours);
        if is_valid then
            try
                data = mda_parse_timeseries_response(cached_res, symbol, exchange, %t);
                return;
            catch
                // If cached payload was corrupted, proceed to live fetch
            end
        end
    end

    // Live fetch requires an API key
    if cfg.api_key == "" | cfg.api_key == "YOUR_TWELVE_DATA_API_KEY_HERE" then
        error("Market data configuration required: No Twelve Data API key configured." + ..
              ascii(10) + "To enable live data:" + ..
              ascii(10) + "1. Obtain a free API key at https://twelvedata.com (free 8 credits/min)." + ..
              ascii(10) + "2. Save it in config/market_data_config.json or set TWELVE_DATA_API_KEY." + ..
              ascii(10) + "You can also switch to bundled synthetic datasets (Tech Growth, Blue Chip, Volatile).");
    end

    // Build URL
    url = cfg.base_url + "/time_series?symbol=" + symbol + "&interval=1day&outputsize=" + ..
          string(outputsize) + "&apikey=" + cfg.api_key;
    if exchange <> "" & exchange <> "AUTO" then
        url = url + "&exchange=" + exchange;
    end

    // Perform HTTP request
    try
        raw_res = http_get(url);
    catch
        net_err = mda_sanitize_error(lasterror(), cfg.api_key);
        error("Market data network error: Unable to reach Twelve Data API (" + net_err + ")." + ..
              ascii(10) + "Please check your internet connection or use bundled offline synthetic datasets.");
    end

    // If http_get returned string rather than struct, parse it
    if typeof(raw_res) == "string" then
        try
            raw_res = fromJSON(raw_res);
        catch
            parse_err = mda_sanitize_error(lasterror(), cfg.api_key);
            error("Market data JSON error: Failed to parse provider response payload (" + parse_err + ").");
        end
    end

    // Parse, validate, normalize
    data = mda_parse_timeseries_response(raw_res, symbol, exchange, %f);

    // Save to cache on success
    if cfg.cache_enabled then
        mda_write_cache(symbol, exchange, outputsize, raw_res);
    end
endfunction


// ---------------------------------------------------------------------------
// 7. Mock Loading Helper (for automated tests and offline verification)
// ---------------------------------------------------------------------------

function data = mda_load_mock(json_path, symbol, exchange)
    if ~isfile(json_path) then
        error("Mock file not found: [" + json_path + "].");
    end
    lines = mgetl(json_path);
    raw = strcat(lines, "");
    parsed = fromJSON(raw);
    data = mda_parse_timeseries_response(parsed, symbol, exchange, %f);
    data.data_freshness = "Offline Mock Fixture (Automated Test)";
    data.source_mode = "MOCK_MARKET";
    data.cache_access_time = "N/A (Mock Fixture)";
endfunction
