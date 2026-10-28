/* C ABI of the Frame2D engine library (src/bridge/exports.zig). Input to ffigen for the desktop bridge.
 *
 * Buffers: every published buffer comes back as address + element count + generation in one call, written
 * to a caller-owned f2d_slice. A view over it is valid only while f2d_generation() still returns `gen`
 * (the engine bumps it on every free/move of a published buffer and, on wasm, on memory growth). Copy what
 * you keep across calls. Status codes: 0 ok, 1 model error (see f2d_error), 2 out of memory, 3 no model /
 * case not solved. */
#ifndef FRAME2D_H
#define FRAME2D_H

#include <stddef.h>
#include <stdint.h>

typedef struct f2d_slice {
  uintptr_t ptr;
  size_t len; /* elements, not bytes */
  uint32_t gen;
  uint32_t _pad;
} f2d_slice;

/* boundary probes */
void f2d_noop(void);
double* f2d_echo(uint32_t n);

/* generation of published buffers */
uint32_t f2d_generation(void);

/* input memory */
uint8_t* f2d_alloc(size_t n);
void f2d_free(uint8_t* p, size_t n);

/* model lifecycle */
int32_t f2d_load_json(const uint8_t* ptr, size_t len);
int32_t f2d_generate(uint32_t bays, uint32_t stories);
int32_t f2d_error(f2d_slice* out);

/* geometry */
uint32_t f2d_node_count(void);
uint32_t f2d_member_count(void);
uint32_t f2d_case_count(void);
int32_t f2d_node_ids(f2d_slice* out);
int32_t f2d_node_xy(f2d_slice* out);
int32_t f2d_node_restraint(f2d_slice* out);
int32_t f2d_member_ids(f2d_slice* out);
int32_t f2d_member_ends(f2d_slice* out);
int32_t f2d_member_len(f2d_slice* out);
int32_t f2d_case_name(uint32_t k, f2d_slice* out);
void f2d_set_node_xy(uint32_t idx, double x, double y);

/* solving */
int32_t f2d_solve(uint32_t mask);
int32_t f2d_stats(f2d_slice* out);
int32_t f2d_disp(uint32_t k, f2d_slice* out);
int32_t f2d_reactions(uint32_t k, f2d_slice* out);
int32_t f2d_end_forces(uint32_t k, f2d_slice* out);
int32_t f2d_max_m(uint32_t k, f2d_slice* out);
int32_t f2d_stations_m(uint32_t k, f2d_slice* out);
double f2d_residual(uint32_t k);

/* JSON out (UTF-8 in the scratch buffer) */
int32_t f2d_export_model(f2d_slice* out);
int32_t f2d_export_results(f2d_slice* out);

/* native only: milliseconds since the process was created, or -1 when unavailable */
double f2d_process_uptime_ms(void);

#endif
