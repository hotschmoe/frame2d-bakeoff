/* C ABI of the Frame2D Zig engine (zig/src/lib.zig). Hand-written; used by cgo (Go CLI/server) and ffigen (Dart). */
#ifndef FRAME2D_ENGINE_H
#define FRAME2D_ENGINE_H

#ifdef __cplusplus
extern "C" {
#endif

/* ---- session API (Flutter desktop via dart:ffi, web via WASM) ----
 * Lifetimes: handles are generation-tagged (a freed handle stays dead even after its slot is reused). Pointers from
 * f2d_geometry/f2d_result/f2d_stats are fixed per session (never reallocated) and valid until f2d_free(h); results
 * are overwritten in place by the next f2d_solve. f2d_to_json and f2d_last_error buffers are valid until the next
 * call of the same function; f2d_echo's until the next f2d_echo. On web every call may grow memory and detach
 * views, so the loader copies everything out. Single-threaded by contract. */
extern void f2d_noop(void);
extern void* f2d_echo(int n);
extern int f2d_load_json(void* data, int n);
extern int f2d_gen(int b, int s);
extern void f2d_free(int h);
extern void* f2d_last_error(void);
extern void f2d_counts(int h, int* out);
extern void* f2d_geometry(int h);
extern void* f2d_result(int h);
extern void* f2d_stats(int h);
/* Returns the length of the ids JSON array; written NUL-terminated into buf only if length + 1 <= capacity. */
extern int f2d_case_ids(int h, char* buf, int capacity);
extern void f2d_set_node(int h, int idx, double x, double y);
extern int f2d_solve(int h, int c);
extern void* f2d_to_json(int h, int* outLen);
extern double f2d_process_age_ms(void);

/* ---- stateless API (Go CLI and server) ----
 * Functions returning rc: 0 ok, 1 bad request (out = error JSON), 2 model error (out = error JSON), 3 internal.
 * Buffers returned through out/out_len are freed with f2d_buf_free. */
extern void f2d_buf_free(void* p, int n);
/* Parses and validates (everything except the numerical solve). */
extern int f2d_check_json(const void* data, int n, void** out, int* out_len);
extern int f2d_solve_json(const void* data, int n, int with_alloc, void** out, int* out_len);
extern int f2d_gen_json(int b, int s, void** out, int* out_len);
extern int f2d_bench(int b, int s, int reps, void** out, int* out_len);

/* sweep: open once, one worker per thread, run variants concurrently */
extern void* f2d_sweep_open(const void* data, int n, void** out, int* out_len, int* rc);
extern void f2d_sweep_close(void* sweep);
extern void* f2d_sweep_worker(void* sweep);
extern void f2d_sweep_worker_free(void* worker);
/* Returns 0, a negative error code (see f2d_code_name) with a message in err, or -100 for out of memory. */
extern int f2d_sweep_run(void* worker, double scale, double* out2, char* err, int err_cap);
/* Name of a negative error code (the "error" field of the error JSON); "internal" for unknown codes. */
extern const char* f2d_code_name(int code);

#ifdef __cplusplus
}
#endif

#endif
