# P5 baseline: `go-flutter` (run1 / win-arm64, as written by the P1-P3 agents)

Your stack's own measured numbers from `results/run1/win-arm64/summary.json` (null = not measured). Sizes in bytes, times in seconds unless the key says ms.

| metric | value |
|---|---|
| `bin_cli` | 2731008 |
| `bin_server` | 10351104 |
| `bin_desktop_bundle` | 30900732 |
| `bin_engine_lib` | 3074560 |
| `bin_web_dir_br` | 12212171 |
| `bin_web_wasm_br` | 942628 |
| `web_transferred_br` | 1570685 |
| `web_uncompressed` | 6824357 |
| `w_tti` | 1929.085 |
| `w_drag_p50` | 124.12 |
| `w_drag_p99` | 222.18 |
| `w_render_p50` | 16.929 |
| `w_solve_p50` | 112.645 |
| `w_runs` | 3 |
| `w_tti_runs` | [11746.395000010729, 1929.0850000083447, 1818.5450000166893] |
| `w_gpu_software` | true |
| `web_flavor` | "Flutter --wasm (skwasm)" |
| `d_runs` | 3 |
| `d_startup` | 975.3214 |
| `d_drag_p50` | 46.35 |
| `d_drag_p99` | 58.368 |
| `d_render_p50` | 15.953 |
| `d_drag_rss` | 369.715 |
| `d_render_rss` | 826.445 |
| `d_renderer` | "[IMPORTANT:flutter/shell/platform/embedder/embedder_surface_gl_impeller.cc(126)] Using the Impeller rendering backend (O" |
| `c_reps` | 3 |
| `c10_fs` | 0 |
| `c10_factor` | 0 |
| `c10_solve` | 0 |
| `c10_rss` | 11.621 |
| `c50_fs` | 20.7062 |
| `c50_factor` | 17.5345 |
| `c50_solve` | 3.1717 |
| `c50_rss` | 29.746 |
| `c100_fs` | 368.8658 |
| `c100_factor` | 333.2159 |
| `c100_solve` | 35.6499 |
| `c100_rss` | 108.777 |
| `c200_fs` | 6365.7172 |
| `c200_factor` | 6109.1013 |
| `c200_solve` | 256.6159 |
| `c200_rss` | 590.234 |
| `s_rps` | 155.1432 |
| `s_p50` | 313.267 |
| `s_p99` | 1575.391 |
| `s_cpu1000` | 103.2168 |
| `s_peak_rss` | 2804.859 |
| `s_threads` | 25 |
| `s_idle_rss` | 55.531 |
| `s_sweep200_wall` | 0.438 |
| `s_sweep1000_wall` | 0.116 |
| `s_sweep200_cores` | 15.04 |
| `s_success` | 1.0 |
| `l_engine` | 1177 |
| `l_ui` | 964 |
| `l_server` | 178 |
| `l_glue` | 784 |
| `l_tests` | 216 |
| `l_total` | 3319 |
| `l_generated` | 303 |
| `cold_cli` | 3.1768 |
| `cold_cli_cpu` | 6.0781 |
| `cold_cli_n` | 2 |
| `cold_server` | 8.3056 |
| `cold_server_cpu` | 25.4688 |
| `cold_server_n` | 2 |
| `cold_desktop` | 40.0616 |
| `cold_desktop_cpu` | 9.8203 |
| `cold_desktop_n` | 2 |
| `cold_web` | 41.1611 |
| `cold_web_cpu` | 6.0078 |
| `cold_web_n` | 2 |
| `cold_dev` | 41.4227 |
| `cold_dev_cpu` | 38.7422 |
| `cold_dev_n` | 2 |
| `leaf_check` | 7.6752 |
| `leaf_check_cpu` | 3.1406 |
| `leaf_check_mem` | 267.2734 |
| `leaf_dev` | 14.5723 |
| `leaf_dev_cpu` | 3.7031 |
| `leaf_dev_mem` | 319.2891 |
| `struct_check` | 7.8476 |
| `struct_check_cpu` | 3.2188 |
| `struct_check_mem` | 323.0625 |
| `struct_dev` | 14.5831 |
| `struct_dev_cpu` | 3.5625 |
| `struct_dev_mem` | 319.9258 |
| `server_check` | 6.6354 |
| `server_check_cpu` | 2.4531 |
| `server_check_mem` | 266.9453 |
| `server_dev` | 13.486 |
| `server_dev_cpu` | 3.0312 |
| `server_dev_mem` | 335.1133 |
| `ui_check` | 6.6726 |
| `ui_check_cpu` | 2.8906 |
| `ui_check_mem` | 267.1992 |
| `ui_dev` | 14.8042 |
| `ui_dev_cpu` | 2.7031 |
| `ui_dev_mem` | 275.3086 |
| `noop_check` | 6.6312 |
| `mean_check` | 7.2077 |
| `noop_dev` | 13.0538 |
| `mean_dev` | 14.3614 |
| `hot_reload` | 0.834 |
| `hot_reload_reps` | [1.3999696999962907, 0.8339761999959592, 0.8008257999899797] |
| `engine_e2e` | 17.6186 |
| `engine_build` | 14.7315 |
| `engine_launch` | 2.7236 |
| `sections` | {"cold": "ok", "edits": "ok", "hotreload": "ok", "engine": "ok"} |
| `bl_failures` | 0 |
| `a_phases` | {"P1": {"wall_corrected_s": 5723.887, "wall_raw_s": 5723.887, "stall_s": 0, "turns": 95, "tool_calls": 112, "build_invocations": 22, "failed_builds": 2, "pure_build_wait_s": 261.338, "pure_build_wait_fraction_of_corrected_wall": 0.0456574352358808, "test_runs": 3, "failed_test_runs": 1, "failures_total": 5, "interventions": 0, "est_cost_usd": 12.422271149999998}, "P2": {"wall_corrected_s": 95.519, "wall_raw_s": 95.519, "stall_s": 0, "turns": 10, "tool_calls": 10, "build_invocations": 3, "failed_builds": 0, "pure_build_wait_s": 15.843, "pure_build_wait_fraction_of_corrected_wall": 0.16586228917806928, "test_runs": 1, "failed_test_runs": 0, "failures_total": 0, "interventions": 0, "est_cost_usd": 0.43529429999999997}} |
| `a_p1_wall` | 5723.887 |
| `a_p2_wall` | 95.519 |
| `a_ttg` | 5819.406 |
| `a_turns` | 105 |
| `a_failed_builds` | 2 |
| `a_cost` | 12.8576 |
| `a_interventions` | 0 |
| `a_buildwait_frac` | 0.0457 |
| `a_builds` | 25 |
| `a_tax_count` | {"type": 0, "ownership": 0, "concurrency_types": 0, "comptime_sema": 0, "strictness": 0, "stale_api": 0, "ffi": 1, "link": 0, "build_config": 2, "runtime_crash": 0, "wrong_result": 1} |
| `a_tax_minutes` | {"type": 0.0, "ownership": 0.0, "concurrency_types": 0.0, "comptime_sema": 0.0, "strictness": 0.0, "stale_api": 0.0, "ffi": 10.0, "link": 0.0, "build_config": 5.199999999999999, "runtime_crash": 0.0, "wrong_result": 0.2} |
| `a_failures_classified` | 4 |
| `a_false_positive` | 1 |
| `a_tax_builds` | 25 |
| `a_stale100` | 0.0 |
| `a_caught_share` | {"compile": 0.25, "own_tests": 0.25, "harness": 0.25, "runtime_manual": 0.25} |
| `a_late_share` | 0.5 |
| `a_tax_total_minutes` | 15.4 |
| `p2_phase` | "P2" |
| `p2_added` | 137 |
| `p2_removed` | 17 |
| `p2_files` | 3 |
| `p2_lines` | 154 |
| `p2_ttg` | 95.519 |
| `p2_failed_builds` | 0 |
| `p2_builds` | 3 |
| `rev_structure` | 4 |
| `rev_naming` | 3 |
| `rev_errors` | 3 |
| `rev_boundary` | 3 |
| `rev_tests` | 2 |
| `rev_change_resilience` | 3 |
| `rev_mean` | 3.0 |
| `rev_notable` | ["Strength: Prepare/solve split lets drag-edit reuse topology and RCM (SetCoord + SolveCase), and Sweep reuses engine code across NumCPU goroutines with per-variant Prepared state.", "Strength: single session package serves both cgo and wasm bridges, so the C ABI and JS API stay in step; flat float64 buffers keep the boundary simple.", "Risk: session.ErrCode has no case for support_conflict, so spring/support conflicts reach the UI as generic code -1 (message still shown via last_error).", "Risk: Session fields and global lastErr have no locking; native f2d_* calls from multiple threads or a stale handle after Free (Dart still holds a view of unpinned memory) are unsafe.", "Weakness: server and CLI have no tests; engine tests skip releases, springs and UDL fixed-end forces; also Sweep reports bad variants count as invalid_ref (misleading code) and the sweepReq field is misspelled BeamIScle."] |
