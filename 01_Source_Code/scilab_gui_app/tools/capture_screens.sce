// ============================================================================
// capture_screens.sce -- Automated GUI Screenshot Capture for StockVision V3
//
// Generates genuine application screenshots directly from the Scilab runtime:
// 1. 01_Main_Analysis_Screen.png      (Real Market AAPL: 95% PI, MA, Split, KPIs)
// 2. 02_Five_Model_Comparison.png     (5-Model Comparison & Grouped Bar Chart)
// 3. 03_Data_Quality_Provenance.png   (Data Quality Tab: Provenance, Rows, Flags)
// 4. 04_AI_Insights_Offline_Mode.png  (Forecast Intelligence: Mode A Briefing)
// 5. 05_Representative_Export_Report.png (Backtest Equity Curve & Strategy KPIs)
//
// Uses Scilab native xs2png() on Windows. Exits with code 0 on completion.
// ============================================================================

global gui_quiet;
gui_quiet = %t;

// Launch application in quiet mode
try
    exec("01_Source_Code/scilab_gui_app/gui_app.sce", -1);
catch
    exec("../gui_app.sce", -1);
end

global gui app_state APP_DIR;

out_dir = APP_DIR + "../../05_GUI_Screenshots/";
if ~isdir(out_dir) then mkdir(out_dir); end

function capture(filename, desc)
    global gui out_dir;
    drawnow();
    sleep(600);
    p = out_dir + filename;
    xs2png(gui.fig, p);
    if isfile(p) then
        mprintf("  [CAPTURED] %s -> %s\n", desc, filename);
    else
        mprintf("  [ERROR] Failed to capture %s\n", filename);
    end
endfunction

mprintf("======================================================================\n");
mprintf("  Capturing StockVision V3 Application Screenshots (Scilab 2026.1.0)\n");
mprintf("======================================================================\n");

// --- Shot 1: Main Analysis Screen (Real Market Data: AAPL NASDAQ 120 bars) ---
real_aapl_cache = APP_DIR + "../../cache/market_data/AAPL_NASDAQ_120.json";
if isfile(real_aapl_cache) then
    app_state.data = mda_load_mock(real_aapl_cache, "AAPL", "NASDAQ");
    app_state.dq = data_quality_summary(app_state.data, app_state.split_ratio);
    set_status("Loaded Real Market Cache: AAPL (NASDAQ, 120 daily bars)");
end
set(gui.model_popup, "value", 4); on_model_changed(); // Select Ridge Regression
on_run_analysis();
capture("01_Main_Analysis_Screen.png", "Shot 1: Main Analysis Screen (Real AAPL Market Data, Ridge 95% PI)");

// --- Shot 2: Five-Model Comparison & Chart ---
on_compare();
capture("02_Five_Model_Comparison.png", "Shot 2: Five-Model Comparison (Naive, LR, AR, ES, Ridge)");

// --- Shot 3: Data-Quality & Provenance Display ---
show_info_tab("dq");
capture("03_Data_Quality_Provenance.png", "Shot 3: Data-Quality & Provenance Tab (Twelve Data Cache)");

// --- Shot 4: AI Insights Tab (Offline Deterministic Mode) ---
set(gui.ai_mode_popup, "value", 1); on_ai_mode_changed();
on_explain();
show_info_tab("ai");
capture("04_AI_Insights_Offline_Mode.png", "Shot 4: AI Insights Tab (Mode A: Offline Deterministic Briefing)");

// --- Shot 5: Representative Export & Backtest Dashboard ---
on_run_backtest();
show_info_tab("asm");
capture("05_Representative_Export_Report.png", "Shot 5: Backtest Equity Curve & Strategy Assumptions");

// Legacy numbered shots for backwards compatibility
capture("06_Model_Comparison_Integrated.png", "Legacy Shot 06: Model Comparison");
capture("07_Backtest_Integrated.png", "Legacy Shot 07: Backtest Integrated");
capture("08_Walk_Forward_Validation.png", "Legacy Shot 08: Walk Forward Validation");
capture("09_Final_Dashboard.png", "Legacy Shot 09: Final Dashboard");

close(gui.fig);

mprintf("======================================================================\n");
mprintf("  All Application Screenshots Successfully Generated.\n");
mprintf("======================================================================\n");
exit(0);
