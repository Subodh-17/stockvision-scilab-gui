// test_gui_workflow.sce -- scripted behavioural test of the integrated dashboard.
// Needs a display (Linux: xvfb-run -a scilab -nw -nb -f test_gui_workflow.sce). Quiet mode: no popups.
global gui_quiet gui app_state nfail; gui_quiet = %t;
exec("gui_app.sce", -1);
nfail = 0;
function ck(c, msg)
    global nfail
    if c then mprintf("OK   : %s\n", msg); else mprintf("FAIL : %s\n", msg); nfail = nfail + 1; end
endfunction
function r = en(h); r = get(h, "enable"); endfunction
function r = first_line(h); s_ = get(h, "string"); r = strsubst(s_(1), "&nbsp;", " "); endfunction

// Initial state
ck(has(app_state.data) & ~has(app_state.analysis), "launch: dataset loaded, no analysis yet");
ck(en(gui.btn_backtest) == "off" & en(gui.btn_export) == "off", "launch: Run Backtest and Export disabled until an analysis exists");
ck(en(gui.btn_run) == "on" & en(gui.btn_compare) == "on" & en(gui.btn_wf) == "on", "launch: Run/Compare/Walk-forward enabled");
ck(strindex(first_line(gui.lb_res), "No analysis yet") <> [], "launch: results panel shows the No-analysis-yet state");
one_fig = size(winsid(), "*");
ck(one_fig == 1, "launch: exactly ONE graphics window exists (found " + string(one_fig) + ")");

// LR / AR / ES each work and fill the integrated panels
for k = 1:3
    set(gui.model_popup, "value", k); on_model_changed();
    ck(~has(app_state.analysis), "model " + string(k) + ": changing model clears the previous analysis");
    on_run_analysis();
    ck(has(app_state.analysis) & app_state.analysis.metrics.rmse > 0, "model " + string(k) + ": Run Analysis -> " + app_state.analysis.name);
    ck(size(gui.ax_main.children, "*") >= 4, "model " + string(k) + ": main chart drawn inside the main figure");
end
ck(size(winsid(), "*") == 1, "after 3 analyses: still exactly one window");
ck(en(gui.btn_backtest) == "on" & en(gui.btn_export) == "on", "after analysis: Run Backtest and Export enabled");

// Compare + walk-forward
on_compare();
ck(has(app_state.cmp) & size(app_state.cmp.M, 1) == 4, "Compare Models: 4-model comparison filled");
ck(size(gui.ax_cmp.children, "*") >= 2, "Compare Models: comparison chart drawn in the main figure");
on_walk_forward();
ck(app_state.cmp.wf.n_used == 5, "Walk Forward: 5 folds used");

// Backtest
on_run_backtest();
ck(has(app_state.bt) & size(gui.ax_eq.children, "*") >= 2, "Run Backtest: equity chart drawn inside the main figure");
ck(abs(app_state.bt.buyhold_final - app_state.bt.starting_capital * (1 - 0.0015) * app_state.analysis.y_true($) / app_state.analysis.y_true(1)) < 1e-6, ..
   "Run Backtest: buy & hold covers the same test window and pays the entry cost");
ck(app_state.bt.transaction_cost_pct == 0.1 & app_state.bt.slippage_pct == 0.05, "Run Backtest: cost 0.1% and slippage 0.05% from the edit boxes were applied");
ck(size(winsid(), "*") == 1, "after backtest: still exactly one window");

// Stale-result protection
set(gui.split_slider, "value", 0.7); on_slider_moved();
ck(~has(app_state.analysis) & ~has(app_state.cmp) & ~has(app_state.bt), "split change clears analysis, comparison and backtest");
ck(strindex(first_line(gui.lb_res), "No analysis yet") <> [], "split change: results panel back to No-analysis-yet");
ck(app_state.dq.train_rows == 210 & app_state.dq.test_rows == 90, "split change: data-quality train/test rows follow the slider (210/90)");
on_run_analysis(); on_compare(); on_run_backtest();
set(gui.dataset_popup, "value", 2); on_dataset_changed();
ck(~has(app_state.analysis) & ~has(app_state.cmp) & ~has(app_state.bt), "dataset change clears everything");
ck(strindex(app_state.dataset_files(2), "blue_chip") <> [] & has(app_state.data), "dataset change: Blue Chip loaded");
on_run_analysis(); on_compare();
set(gui.ed_lookback, "string", "15"); on_model_params_changed();
ck(~has(app_state.analysis) & ~has(app_state.cmp), "AR lookback change clears results");
on_run_analysis(); on_compare(); on_run_backtest();
set(gui.ed_cost, "string", "0.5"); on_strategy_changed();
ck(~has(app_state.bt) & has(app_state.analysis) & has(app_state.cmp), "cost change clears only the backtest");
set(gui.ed_folds, "string", "3"); on_model_params_changed();
ck(~has(app_state.cmp) & has(app_state.analysis), "fold-count change clears only the comparison");

// Input validation
set(gui.ed_buy, "string", "abc"); on_strategy_changed();
ck(strindex(get(gui.status, "string"), "Buy threshold must be a plain number") <> [], "invalid threshold -> clear status-bar error, no popup");
set(gui.ed_buy, "string", "0.5");
set(gui.ed_lookback, "string", "1"); on_model_params_changed();
ck(strindex(get(gui.status, "string"), "AR lookback") <> [], "invalid lookback -> clear status-bar error");
set(gui.ed_lookback, "string", "10"); on_model_params_changed();

// Export
on_run_analysis(); on_compare(); on_run_backtest();
exp_dir = TMPDIR + "/sv_export/"; mkdir(exp_dir);
m1 = export_to(exp_dir + "gui_export.txt");
m2 = export_to(exp_dir + "gui_export.txt");
ck(isfile(exp_dir + "gui_export.txt") & isfile(exp_dir + "gui_export_2.txt"), "Export: TXT written; a second export does not overwrite the first");
files = ls(exp_dir);
ck(size(grep(files, "_predictions.csv"), "*") >= 1 & size(grep(files, "_walkforward.csv"), "*") >= 1 & size(grep(files, "_backtest.csv"), "*") >= 1, "Export: companion CSV tables written");
export_to(exp_dir + "gui_export.csv");
ck(isfile(exp_dir + "gui_export.csv"), "Export: single CSV written");
export_to(exp_dir + "gui_charts.pdf");
ck(isfile(exp_dir + "gui_charts.pdf"), "Export: charts PDF written");
ck(size(winsid(), "*") == 1, "after exports: still exactly one window");
on_model_info(); ck(%t, "Model Info callback runs");

// Reset
on_reset();
ck(~has(app_state.analysis) & ~has(app_state.cmp) & ~has(app_state.bt) & app_state.dataset_idx == 1 & app_state.split_ratio == 0.8 & ..
   get(gui.ed_cost, "string") == "0.1" & app_state.ar_lookback == 10, "Reset: defaults restored and results cleared");
ck(en(gui.btn_backtest) == "off" & en(gui.btn_export) == "off", "Reset: Run Backtest / Export disabled again");
// Bad CSV is reported, not crashed
bad = TMPDIR + "/bad.csv"; mputl(["Date,Open,High,Low,Close,Vol"; "2024-01-01,1,2,1,1,5"], bad);
app_state.custom_path = bad; app_state.dataset_idx = 4;
ok = load_current_dataset();
ck(~ok & ~has(app_state.data), "bad CSV: load fails cleanly with an error, no crash");
mprintf("\nGUI VERIFICATION: %d failure(s)\n", nfail);
exit;
