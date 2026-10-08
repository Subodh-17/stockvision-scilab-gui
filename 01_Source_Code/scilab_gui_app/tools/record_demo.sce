global gui_quiet gui app_state; gui_quiet = %t;
exec("../gui_app.sce", -1);
function wait_until(t)
    while toc() < t
        sleep(100);
    end
endfunction
sleep(2500);
disp_name = getenv("DISPLAY");
unix("ffmpeg -y -loglevel error -f x11grab -framerate 10 -video_size 1500x980 -i " + disp_name + "+0,0 -c:v libx264 -preset ultrafast -crf 24 -pix_fmt yuv420p /tmp/demo_raw.mp4 > /dev/null 2>&1 &");
sleep(1500);
tic();
mprintf("REC_START\n");
wait_until(9);   show_info_tab("dq");
wait_until(14);  use_custom_csv(pwd() + "/../sample_data/messy_demo_data_quality.csv");
wait_until(22);  on_reset();
wait_until(24);  set(gui.model_popup, "value", 1); on_model_changed(); on_run_analysis();
wait_until(39);  set(gui.model_popup, "value", 2); on_model_changed(); on_run_analysis();
wait_until(47);  set(gui.model_popup, "value", 3); on_model_changed(); on_run_analysis();
wait_until(55);  set(gui.model_popup, "value", 1); on_model_changed(); on_compare();
wait_until(75);  on_run_backtest();
wait_until(93);  on_walk_forward();
wait_until(107);
mprintf("REC_END at %f s\n", toc());
unix("pkill -INT -x ffmpeg");
sleep(3000);
exit;
