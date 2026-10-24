/* C ABI of the Frame2D engine library (src/bridge/exports.zig). Input to ffigen for the desktop bridge. */
#ifndef FRAME2D_H
#define FRAME2D_H

#include <stddef.h>
#include <stdint.h>

/* boundary probes */
void f2d_noop(void);
double* f2d_echo(uint32_t n);

/* input memory */
uint8_t* f2d_alloc(size_t n);
void f2d_free(uint8_t* p, size_t n);

/* model lifecycle: return 0 on success, 1 model error (see f2d_error_*), 2 out of memory, 3 no model */
int32_t f2d_load_json(const uint8_t* ptr, size_t len);
int32_t f2d_generate(uint32_t bays, uint32_t stories);
const uint8_t* f2d_error_ptr(void);
size_t f2d_error_len(void);

/* geometry */
uint32_t f2d_node_count(void);
uint32_t f2d_member_count(void);
uint32_t f2d_case_count(void);
const int32_t* f2d_node_ids(void);
const double* f2d_node_xy(void);
const uint8_t* f2d_node_restraint(void);
const int32_t* f2d_member_ids(void);
const uint32_t* f2d_member_ends(void);
const double* f2d_member_len(void);
const uint8_t* f2d_case_name_ptr(uint32_t k);
size_t f2d_case_name_len(uint32_t k);
void f2d_set_node_xy(uint32_t idx, double x, double y);

/* solving */
int32_t f2d_solve(uint32_t mask);
const double* f2d_stats(void);
const double* f2d_disp(uint32_t k);
const double* f2d_reactions(uint32_t k);
const double* f2d_end_forces(uint32_t k);
const double* f2d_max_m(uint32_t k);
const double* f2d_stations_m(uint32_t k);
double f2d_residual(uint32_t k);

/* JSON out */
size_t f2d_export_model(void);
size_t f2d_export_results(void);
const uint8_t* f2d_out_ptr(void);

/* native only: milliseconds since the process was created, or -1 when unavailable */
double f2d_process_uptime_ms(void);

#endif
