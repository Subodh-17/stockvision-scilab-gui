// ============================================================================
// tools/run_benchmarks.sce -- Shortcut runner for Phase 6 benchmarks
// ============================================================================

try
    T_DIR = get_absolute_file_path("run_benchmarks.sce");
catch
    T_DIR = pwd() + filesep();
end

exec(T_DIR + "../run_reproducible_benchmark.sce", -1);
