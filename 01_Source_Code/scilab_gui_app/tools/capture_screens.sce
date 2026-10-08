global gui_quiet gui app_state; gui_quiet = %t;
exec("../gui_app.sce", -1);
function shot(name)
    drawnow(); sleep(1800);
    unix_g("import -window root /tmp/shots/" + name + ".png");
endfunction
sleep(1000);
shot("01_Main_GUI");

use_custom_csv(pwd() + "/../sample_data/messy_demo_data_quality.csv");
show_info_tab("dq"); shot("02_Data_Quality");
on_reset();

set(gui.model_popup, "value", 1); on_model_changed(); on_run_analysis(); shot("03_Linear_Regression_Integrated");
set(gui.model_popup, "value", 2); on_model_changed(); on_run_analysis(); shot("04_AR_Time_Series_Integrated");
set(gui.model_popup, "value", 3); on_model_changed(); on_run_analysis(); shot("05_Exponential_Smoothing_Integrated");

on_reset(); on_compare(); shot("06_Model_Comparison_Integrated");

on_reset(); on_run_analysis(); on_run_backtest(); shot("07_Backtest_Integrated");

on_reset(); set(gui.dataset_popup, "value", 3); on_dataset_changed();
set(gui.ed_folds, "string", "6"); on_model_params_changed(); on_walk_forward(); shot("08_Walk_Forward_Validation");

on_reset(); on_run_analysis(); on_compare(); on_run_backtest(); shot("09_Final_Dashboard");
mprintf("SHOTS DONE\n");
exit;
