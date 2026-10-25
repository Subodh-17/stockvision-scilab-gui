// ============================================================================
// tools/test_benchmark_nocache.sce -- Regression Test: Offline No-Cache Benchmark
//
// Verifies that run_reproducible_benchmark.sce executes cleanly without errors
// when local market data caches are absent or disabled, correctly assembling
// a 5-dataset offline evaluation matrix from bundled fixtures and CSVs.
// ============================================================================

clear; clc;

try
    T_DIR = get_absolute_file_path("test_benchmark_nocache.sce");
catch
    T_DIR = pwd() + filesep();
end

mprintf("======================================================================\n");
mprintf("  Regression Test: Offline No-Cache Benchmark Execution\n");
mprintf("======================================================================\n\n");

// Force offline mode and isolated output directory via environment variables
setenv("STOCKVISION_NO_CACHE", "1");
temp_out = TMPDIR + filesep() + "stockvision_benchmark_nocache" + filesep();
if ~isdir(temp_out) then mkdir(temp_out); end
setenv("STOCKVISION_BENCHMARK_OUT", temp_out);

// Execute benchmark runner
exec(T_DIR + "../run_reproducible_benchmark.sce", -1);

// Restore default environment
setenv("STOCKVISION_NO_CACHE", "0");
setenv("STOCKVISION_BENCHMARK_OUT", "");

// Verify execution outcomes
global n_bm_pass n_bm_fail;
nocache_pass = (n_bm_fail == 0 & n_bm_pass >= 90);

mprintf("\n--- Regression Assertion Verification ---\n");
if nocache_pass then
    mprintf("  [PASS] Offline benchmark executed with 0 failures (%d assertions passed).\n", n_bm_pass);
    mprintf("  [PASS] Successfully assembled and evaluated bundled offline datasets.\n");
    mprintf("======================================================================\n");
    mprintf("REGRESSION TEST PASSED: No-cache benchmark resilience verified.\n");
    exit(0);
else
    mprintf("  [FAIL] Offline benchmark encountered %d failures.\n", n_bm_fail);
    mprintf("======================================================================\n");
    exit(1);
end
