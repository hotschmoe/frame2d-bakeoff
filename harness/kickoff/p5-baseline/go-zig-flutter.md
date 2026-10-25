# P5 baseline: `go-zig-flutter` (run1 / win-arm64, as written by the P1-P3 agents)

Your stack's own measured numbers from `results/run1/win-arm64/summary.json` (null = not measured). Sizes in bytes, times in seconds unless the key says ms.

| metric | value |
|---|---|
| `bin_cli` | 3024384 |
| `bin_server` | 10730496 |
| `bin_desktop_bundle` | 28166652 |
| `bin_engine_lib` | 340480 |
| `bin_web_dir_br` | 11344183 |
| `bin_web_wasm_br` | 77705 |
| `web_transferred_br` | 702256 |
| `web_uncompressed` | 2430410 |
| `w_tti` | 2158.715 |
| `w_drag_p50` | 23.686 |
| `w_drag_p99` | 209.8 |
| `w_render_p50` | 17.13 |
| `w_solve_p50` | 14.08 |
| `w_runs` | 3 |
| `w_tti_runs` | [11965.65000000596, 2158.7150000035763, 2140.145000010729] |
| `w_gpu_software` | true |
| `web_flavor` | "Flutter --wasm (skwasm)" |
| `d_runs` | 3 |
| `d_startup` | 927.9442 |
| `d_drag_p50` | 30.469 |
| `d_drag_p99` | 41.255 |
| `d_render_p50` | 15.914 |
| `d_drag_rss` | 356.176 |
| `d_render_rss` | 788.297 |
| `d_renderer` | "[IMPORTANT:flutter/shell/platform/embedder/embedder_surface_gl_impeller.cc(126)] Using the Impeller rendering backend (O" |
| `c_reps` | 3 |
| `c10_fs` | 0.0534 |
| `c10_factor` | 0.0289 |
| `c10_solve` | 0.0245 |
| `c10_rss` | 9.059 |
| `c50_fs` | 7.4338 |
| `c50_factor` | 6.1443 |
| `c50_solve` | 1.2895 |
| `c50_rss` | 17.887 |
| `c100_fs` | 125.2508 |
| `c100_factor` | 101.7901 |
| `c100_solve` | 23.4607 |
| `c100_rss` | 68.652 |
| `c200_fs` | 1715.4063 |
| `c200_factor` | 1552.1307 |
| `c200_solve` | 163.2756 |
| `c200_rss` | 427.816 |
| `s_rps` | 180.1989 |
| `s_p50` | 281.583 |
| `s_p99` | 1122.695 |
| `s_cpu1000` | 92.2733 |
| `s_peak_rss` | 2552.668 |
| `s_threads` | 62 |
| `s_idle_rss` | 62.523 |
| `s_sweep200_wall` | 0.232 |
| `s_sweep1000_wall` | 0.027 |
| `s_sweep200_cores` | 14.1 |
| `s_success` | 1.0 |
| `l_engine` | 1882 |
| `l_ui` | 964 |
| `l_server` | 201 |
| `l_glue` | 1032 |
| `l_tests` | 294 |
| `l_total` | 4373 |
| `l_generated` | 404 |
| `cold_cli` | 17.2298 |
| `cold_cli_cpu` | 43.2422 |
| `cold_cli_n` | 2 |
| `cold_server` | 21.0824 |
| `cold_server_cpu` | 61.3984 |
| `cold_server_n` | 2 |
| `cold_desktop` | 37.8414 |
| `cold_desktop_cpu` | 4.5547 |
| `cold_desktop_n` | 2 |
| `cold_web` | 41.8439 |
| `cold_web_cpu` | 4.0078 |
| `cold_web_n` | 2 |
| `cold_dev` | 63.9147 |
| `cold_dev_cpu` | 74.2891 |
| `cold_dev_n` | 2 |
| `leaf_check` | 11.738 |
| `leaf_check_cpu` | 8.4375 |
| `leaf_check_mem` | 448.8984 |
| `leaf_dev` | 28.9988 |
| `leaf_dev_cpu` | 18.8438 |
| `leaf_dev_mem` | 450.8086 |
| `struct_check` | 11.6599 |
| `struct_check_cpu` | 8.3906 |
| `struct_check_mem` | 450.7695 |
| `struct_dev` | 28.9113 |
| `struct_dev_cpu` | 18.6406 |
| `struct_dev_mem` | 459.5 |
| `server_check` | 11.7522 |
| `server_check_cpu` | 8.4375 |
| `server_check_mem` | 448.8164 |
| `server_dev` | 28.9613 |
| `server_dev_cpu` | 18.6406 |
| `server_dev_mem` | 461.875 |
| `ui_check` | 11.627 |
| `ui_check_cpu` | 8.2969 |
| `ui_check_mem` | 452.2773 |
| `ui_dev` | 30.9769 |
| `ui_dev_cpu` | 18.6406 |
| `ui_dev_mem` | 455.4297 |
| `noop_check` | 11.6929 |
| `mean_check` | 11.6943 |
| `noop_dev` | 28.8489 |
| `mean_dev` | 29.4621 |
| `hot_reload` | 0.8829 |
| `hot_reload_reps` | [0.8701690999732818, 0.8828706000058446, 0.8848289000161458] |
| `engine_e2e` | 31.5309 |
| `engine_build` | 28.7989 |
| `engine_launch` | 2.7186 |
| `sections` | {"cold": "ok", "edits": "ok", "hotreload": "ok", "engine": "ok"} |
| `bl_failures` | 0 |
| `a_phases` | {"P3": {"wall_corrected_s": 2839.0469999999987, "wall_raw_s": 26214.856, "stall_s": 23375.809, "turns": 88, "tool_calls": 89, "build_invocations": 10, "failed_builds": 2, "pure_build_wait_s": 55.026, "pure_build_wait_fraction_of_corrected_wall": 0.019381855953776048, "test_runs": 1, "failed_test_runs": 0, "failures_total": 2, "interventions": 0, "est_cost_usd": 10.15881975}} |
| `a_p3_wall` | 2839.047 |
| `a_p3_stall` | 23375.809 |
| `a_p3_turns` | 88 |
| `a_p3_failed_builds` | 2 |
| `a_p3_cost` | 10.1588 |
| `a_p3_interventions` | 0 |
| `a_p3_builds` | 10 |
| `a_tax_count` | {"type": 0, "ownership": 0, "concurrency_types": 0, "comptime_sema": 0, "strictness": 1, "stale_api": 0, "ffi": 0, "link": 0, "build_config": 1, "runtime_crash": 0, "wrong_result": 0} |
| `a_tax_minutes` | {"type": 0.0, "ownership": 0.0, "concurrency_types": 0.0, "comptime_sema": 0.0, "strictness": 0.1, "stale_api": 0.0, "ffi": 0.0, "link": 0.0, "build_config": 1.0, "runtime_crash": 0.0, "wrong_result": 0.0} |
| `a_failures_classified` | 2 |
| `a_false_positive` | 0 |
| `a_tax_builds` | 10 |
| `a_stale100` | 0.0 |
| `a_caught_share` | {"compile": 0.5, "own_tests": 0.0, "harness": 0.0, "runtime_manual": 0.5} |
| `a_late_share` | 0.5 |
| `a_tax_total_minutes` | 1.1 |
| `p2_phase` | "P3" |
| `p2_added` | 3096 |
| `p2_removed` | 1938 |
| `p2_files` | 35 |
| `p2_lines` | 5034 |
| `p2_ttg` | 2839.047 |
| `p2_failed_builds` | 2 |
| `p2_builds` | 10 |
| `rev_structure` | 4 |
| `rev_naming` | 4 |
| `rev_errors` | 4 |
| `rev_boundary` | 3 |
| `rev_tests` | 3 |
| `rev_change_resilience` | 3 |
| `rev_mean` | 3.5 |
| `rev_notable` | ["Strength: single error path (Diag -> abi code -> rc -> typed Go errors -> exit 2/422/UI banner) is consistent across all three consumers.", "Strength: sweep uses Prepared.fork so each goroutine owns its own stiffness/workspace while sharing immutable topology; clean concurrent design.", "Risk: lib.zig session table, last_error and echo_buf are unsynchronized process globals (fine for single-threaded Dart/WASM, unsafe if the shared lib is ever called from multiple threads; Go Echo/EchoView share the same buffer).", "Risk: f2d_gen and f2d_load_json OOM/null-data paths return -1 without updating last_error, so UI may show a stale or empty message; f2d_load_json also leaks its arena on those early returns.", "Gap: POST /models only parses (Check) so models with invalid refs are stored and fail later at solve; app/ffigen/frame2d_engine.h duplicates zig/include header and Go codeName() duplicates Code.abi() (drift risk)."] |
