//! C ABI of the Frame2D engine (include/frame2d_engine.h). One source, three consumers:
//!  - static library for the Go CLI/server (cgo, `zig cc` as CC): stateless f2d_solve_json / f2d_sweep_* / f2d_bench
//!  - shared library for the Flutter desktop app (dart:ffi): session API f2d_load_json ... f2d_solve
//!  - wasm32-freestanding module for Flutter web (loaded by web/f2d_loader.js): same session API
const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine.zig");
const model = @import("model.zig");
const results = @import("results.zig");
const session = @import("session.zig");
const util = @import("util.zig");

const gpa = util.backing;
const is_wasm = builtin.cpu.arch.isWasm();

// ---------------------------------------------------------------- shared state (session API)

// Handles are generation-tagged: handle = gen * max_sessions + slot + 1. f2d_free bumps the slot's generation, so a
// stale handle (freed, slot since reused by another session) resolves to null instead of aliasing the new session and
// letting the caller read its buffers with the old session's lengths. Session buffers (geometry, results, stats) are
// allocated once per session and never reallocated, so a pointer from f2d_geometry/f2d_result/f2d_stats is valid
// exactly until f2d_free of its handle.
const max_sessions = 256;
const max_gen = @divTrunc(std.math.maxInt(c_int), max_sessions) - 1; // keeps every handle a positive c_int
var sessions: [max_sessions]?*session.Session = @splat(null);
var slot_gen: [max_sessions]c_int = @splat(0);
// Message of the last failing session call; f2d_last_error points here and callers copy it out immediately.
var last_error: [256]u8 = @splat(0);

fn setError(d: *const model.Diag) void {
    const text = std.fmt.bufPrint(last_error[0 .. last_error.len - 1], "{s}: {s}", .{ d.code.name(), d.detail() }) catch last_error[0 .. last_error.len - 1];
    last_error[text.len] = 0;
}

/// Record a bad_request message for f2d_last_error and return its ABI code (-1).
fn fail(d: *model.Diag, comptime msg: []const u8) c_int {
    _ = d.set(.bad_request, msg, .{}) catch {};
    setError(d);
    return d.code.abi();
}

fn slotOf(h: c_int) ?usize {
    if (h < 1) return null;
    const k: usize = @intCast(@mod(h - 1, max_sessions));
    if (@divTrunc(h - 1, max_sessions) != slot_gen[k]) return null;
    return k;
}

fn getSession(h: c_int) ?*session.Session {
    return sessions[slotOf(h) orelse return null];
}

fn register(ar: std.heap.ArenaAllocator, m: model.Model, d: *model.Diag) c_int {
    const s = session.create(ar, m, d) catch |e| {
        if (e == error.OutOfMemory) _ = d.set(.bad_request, "out of memory", .{}) catch {};
        setError(d);
        return d.code.abi();
    };
    for (&sessions, 0..) |*slot, k| if (slot.* == null) {
        slot.* = s;
        return slot_gen[k] * max_sessions + @as(c_int, @intCast(k)) + 1;
    };
    session.destroy(s);
    _ = d.set(.bad_request, "too many open sessions", .{}) catch {};
    setError(d);
    return d.code.abi();
}

// ---------------------------------------------------------------- memory helpers (WASM glue, buffers to the caller)

export fn f2d_alloc(n: c_int) ?[*]u8 {
    const buf = gpa.alignedAlloc(u8, .@"16", @intCast(@max(n, 1))) catch return null;
    return buf.ptr;
}

export fn f2d_dealloc(p: ?[*]u8, n: c_int) void {
    if (p) |ptr| gpa.free(@as([*]align(16) u8, @ptrCast(@alignCast(ptr)))[0..@intCast(@max(n, 1))]);
}

/// Free a buffer returned through an `out`/`out_len` pair.
export fn f2d_buf_free(p: ?[*]u8, n: c_int) void {
    if (p) |ptr| if (n > 0) gpa.free(ptr[0..@intCast(n)]);
}

// ---------------------------------------------------------------- session API (Flutter)

export fn f2d_noop() void {}

var echo_buf: []f64 = &.{};

export fn f2d_echo(n: c_int) ?[*]f64 {
    const len: usize = @intCast(@max(n, 0));
    if (echo_buf.len != len) {
        if (echo_buf.len > 0) gpa.free(echo_buf);
        echo_buf = gpa.alloc(f64, len) catch return null;
        for (echo_buf, 0..) |*v, k| v.* = @floatFromInt(k);
    }
    return echo_buf.ptr;
}

export fn f2d_load_json(data: ?[*]const u8, n: c_int) c_int {
    var d = model.Diag{};
    const src = data orelse return fail(&d, "no model data");
    if (n < 0) return fail(&d, "negative model length");
    var ar = std.heap.ArenaAllocator.init(gpa);
    const a = ar.allocator();
    const text = a.dupe(u8, src[0..@intCast(n)]) catch {
        ar.deinit();
        return fail(&d, "out of memory");
    };
    const m = model.parseModel(a, text, &d) catch |e| {
        ar.deinit();
        if (e == error.OutOfMemory) return fail(&d, "out of memory");
        setError(&d);
        return d.code.abi();
    };
    return register(ar, m, &d);
}

pub export fn f2d_gen(bays: c_int, stories: c_int) c_int {
    var d = model.Diag{};
    var ar = std.heap.ArenaAllocator.init(gpa);
    const m = model.gen(ar.allocator(), @intCast(@max(bays, 1)), @intCast(@max(stories, 1))) catch {
        ar.deinit();
        return fail(&d, "out of memory");
    };
    return register(ar, m, &d);
}

pub export fn f2d_free(h: c_int) void {
    const k = slotOf(h) orelse return;
    const s = sessions[k] orelse return;
    sessions[k] = null;
    slot_gen[k] = if (slot_gen[k] >= max_gen) 0 else slot_gen[k] + 1;
    session.destroy(s);
}

export fn f2d_last_error() [*]const u8 {
    return &last_error;
}

/// Writes {nodes, members, cases}; all zero for a dead handle (callers size their reads from this).
pub export fn f2d_counts(h: c_int, out: *[3]c_int) void {
    out.* = if (getSession(h)) |s| s.counts() else .{ 0, 0, 0 };
}

pub export fn f2d_geometry(h: c_int) ?[*]f64 {
    return if (getSession(h)) |s| s.geo.ptr else null;
}

pub export fn f2d_result(h: c_int) ?[*]f64 {
    return if (getSession(h)) |s| s.res.ptr else null;
}

pub export fn f2d_stats(h: c_int) ?[*]f64 {
    return if (getSession(h)) |s| &s.stats else null;
}

/// Returns the length of the load case ids JSON array; when it fits (length + 1 <= capacity) it is also written
/// into buf, NUL-terminated. A caller whose buffer was too small calls again with a larger one.
export fn f2d_case_ids(h: c_int, buf: [*]u8, capacity: c_int) c_int {
    const s = getSession(h) orelse return 0;
    if (s.case_ids.len + 1 <= @as(usize, @intCast(@max(capacity, 0)))) {
        @memcpy(buf[0..s.case_ids.len], s.case_ids);
        buf[s.case_ids.len] = 0;
    }
    return @intCast(s.case_ids.len);
}

pub export fn f2d_set_node(h: c_int, idx: c_int, x: f64, y: f64) void {
    if (getSession(h)) |s| if (idx >= 0) s.setNode(@intCast(idx), x, y);
}

pub export fn f2d_solve(h: c_int, c: c_int) c_int {
    const s = getSession(h) orelse return -1;
    var d = model.Diag{};
    s.solve(c, &d) catch |e| {
        if (e == error.OutOfMemory) _ = d.set(.bad_request, "out of memory", .{}) catch {};
        setError(&d);
        return d.code.abi();
    };
    return 0;
}

/// Returns the serialized model and its length together (out_len; 0 with a null pointer on failure). The buffer is
/// owned by the session and valid until the next f2d_to_json or f2d_free of that handle: copy it out before any
/// other call (on web, any call may also grow memory).
pub export fn f2d_to_json(h: c_int, out_len: *c_int) ?[*]const u8 {
    out_len.* = 0;
    const s = getSession(h) orelse return null;
    const j = s.toJson() catch return null;
    out_len.* = @intCast(j.len);
    return j.ptr;
}

// Milliseconds since process start (0 when unknown).
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcessTimes(h: ?*anyopaque, c: *u64, e: *u64, k: *u64, u: *u64) callconv(.winapi) i32;
extern "kernel32" fn GetSystemTimeAsFileTime(t: *u64) callconv(.winapi) void;

export fn f2d_process_age_ms() f64 {
    if (comptime builtin.os.tag != .windows) return 0;
    var c: u64 = 0;
    var e: u64 = 0;
    var k: u64 = 0;
    var u: u64 = 0;
    if (GetProcessTimes(GetCurrentProcess(), &c, &e, &k, &u) == 0) return 0;
    var now: u64 = 0;
    GetSystemTimeAsFileTime(&now);
    return @as(f64, @floatFromInt(now -| c)) / 1.0e4; // 100 ns ticks -> ms
}

// ---------------------------------------------------------------- stateless API (Go CLI and server)

/// Return codes of the *_json functions.
const rc_ok = 0;
const rc_bad_request = 1; // out holds {"error":"bad_request",...}
const rc_model_error = 2; // out holds {"error":<code>,...}
const rc_internal = 3; // out is empty
const rc_oom: c_int = -100; // f2d_sweep_run: out of memory (the other negative codes are Code.abi() values)

fn outBytes(b: *util.Buf, out: *?[*]u8, out_len: *c_int) c_int {
    const s = b.finish() catch {
        out.* = null;
        out_len.* = 0;
        return rc_internal;
    };
    out.* = if (s.len > 0) s.ptr else null;
    out_len.* = @intCast(s.len);
    return rc_ok;
}

fn errOut(d: *const model.Diag, out: *?[*]u8, out_len: *c_int) c_int {
    var b = util.Buf{ .a = gpa };
    d.writeJson(&b) catch return rc_internal;
    const r = outBytes(&b, out, out_len);
    if (r != rc_ok) return r;
    return if (d.code == .bad_request) rc_bad_request else rc_model_error;
}

/// Parse + validate (parse and prepare, no solve): rc_ok, or an error as above.
export fn f2d_check_json(data: ?[*]const u8, n: c_int, out: *?[*]u8, out_len: *c_int) c_int {
    var d = model.Diag{};
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const m = model.parseModel(ar.allocator(), (data orelse return rc_internal)[0..@intCast(n)], &d) catch |e| {
        if (e == error.OutOfMemory) return rc_internal;
        return errOut(&d, out, out_len);
    };
    // Validate references, ids, lengths and supports too (everything but the numerical solve), so a stored model
    // is one that can at least be prepared.
    const p = engine.prepare(gpa, &m, &d) catch |e| {
        if (e == error.OutOfMemory) return rc_internal;
        return errOut(&d, out, out_len);
    };
    p.deinit();
    out.* = null;
    out_len.* = 0;
    return rc_ok;
}

const SolveResult = struct { alloc: ?results.AllocStats = null };

/// Prepare + solve every load case of `m`, writing results JSON. With `with_alloc` the alloc fields are filled
/// from a counting allocator wrapped around the engine's allocator (prepare + solve, not parsing or output).
fn solveModel(m: *const model.Model, with_alloc: bool, b: *util.Buf, d: *model.Diag) model.Error!void {
    var counting = util.Counting.init(gpa);
    const ea = if (with_alloc) counting.allocator() else gpa;
    const p = try engine.prepare(ea, m, d);
    defer p.deinit();
    var ar = std.heap.ArenaAllocator.init(ea);
    defer ar.deinit();
    const outs = try ar.allocator().alloc(engine.CaseOut, p.cases.len);
    for (outs) |*o| o.* = try engine.CaseOut.alloc(ar.allocator(), p);
    var st: engine.Stats = undefined;
    try engine.solve(p, null, outs, &st, d);
    const al: ?results.AllocStats = if (with_alloc) .{ .count = counting.count, .bytes = counting.bytes, .peak = counting.peak } else null;
    try results.writeResults(b, p, outs, st, al);
}

export fn f2d_solve_json(data: ?[*]const u8, n: c_int, with_alloc: c_int, out: *?[*]u8, out_len: *c_int) c_int {
    var d = model.Diag{};
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const m = model.parseModel(ar.allocator(), (data orelse return rc_internal)[0..@intCast(n)], &d) catch |e| {
        if (e == error.OutOfMemory) return rc_internal;
        return errOut(&d, out, out_len);
    };
    var b = util.Buf{ .a = gpa };
    solveModel(&m, with_alloc != 0, &b, &d) catch |e| {
        if (b.list.buf.len > 0) gpa.free(b.list.buf);
        if (e == error.OutOfMemory) return rc_internal;
        return errOut(&d, out, out_len);
    };
    return outBytes(&b, out, out_len);
}

export fn f2d_gen_json(bays: c_int, stories: c_int, out: *?[*]u8, out_len: *c_int) c_int {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const m = model.gen(ar.allocator(), @intCast(@max(bays, 1)), @intCast(@max(stories, 1))) catch return rc_internal;
    var b = util.Buf{ .a = gpa };
    model.writeModel(&b, &m) catch return rc_internal;
    return outBytes(&b, out, out_len);
}

fn median(v: []f64) f64 {
    std.mem.sort(f64, v, {}, std.sort.asc(f64));
    return v[v.len / 2];
}

/// gen + solve `reps` times; JSON with median timings and the allocation stats of the last repetition.
export fn f2d_bench(bays: c_int, stories: c_int, reps: c_int, out: *?[*]u8, out_len: *c_int) c_int {
    const nrep: usize = @intCast(@max(reps, 1));
    const t = gpa.alloc(f64, nrep * 3) catch return rc_internal;
    defer gpa.free(t);
    var last_st: engine.Stats = .{};
    var last_al: results.AllocStats = .{ .count = 0, .bytes = 0, .peak = 0 };
    var d = model.Diag{};
    for (0..nrep) |r| {
        var mar = std.heap.ArenaAllocator.init(gpa);
        defer mar.deinit();
        const m = model.gen(mar.allocator(), @intCast(@max(bays, 1)), @intCast(@max(stories, 1))) catch return rc_internal;
        var counting = util.Counting.init(gpa);
        const ea = counting.allocator();
        const p = engine.prepare(ea, &m, &d) catch return errOut(&d, out, out_len);
        defer p.deinit();
        var ar = std.heap.ArenaAllocator.init(ea);
        defer ar.deinit();
        const outs = ar.allocator().alloc(engine.CaseOut, p.cases.len) catch return rc_internal;
        for (outs) |*o| o.* = engine.CaseOut.alloc(ar.allocator(), p) catch return rc_internal;
        engine.solve(p, null, outs, &last_st, &d) catch return errOut(&d, out, out_len);
        t[r] = last_st.assemble_ms;
        t[nrep + r] = last_st.factor_ms;
        t[2 * nrep + r] = last_st.solve_ms;
        last_al = .{ .count = counting.count, .bytes = counting.bytes, .peak = counting.peak };
    }
    last_st.assemble_ms = median(t[0..nrep]);
    last_st.factor_ms = median(t[nrep .. 2 * nrep]);
    last_st.solve_ms = median(t[2 * nrep .. 3 * nrep]);
    var b = util.Buf{ .a = gpa };
    const ok = blk: {
        b.raw("{\"bays\":") catch break :blk false;
        b.int(bays) catch break :blk false;
        b.raw(",\"stories\":") catch break :blk false;
        b.int(stories) catch break :blk false;
        b.raw(",\"reps\":") catch break :blk false;
        b.int(nrep) catch break :blk false;
        b.raw(",\"stats\":") catch break :blk false;
        results.writeStats(&b, last_st, last_al) catch break :blk false;
        b.byte('}') catch break :blk false;
        break :blk true;
    };
    if (!ok) return rc_internal;
    return outBytes(&b, out, out_len);
}

// ---- sweep: one shared base, one worker per thread

export fn f2d_sweep_open(data: ?[*]const u8, n: c_int, out: *?[*]u8, out_len: *c_int, rc: *c_int) ?*anyopaque {
    var d = model.Diag{};
    const base = results.sweepOpen(gpa, (data orelse {
        rc.* = rc_internal;
        return null;
    })[0..@intCast(n)], &d) catch |e| {
        rc.* = if (e == error.OutOfMemory) rc_internal else errOut(&d, out, out_len);
        return null;
    };
    rc.* = rc_ok;
    return base;
}

export fn f2d_sweep_close(h: ?*anyopaque) void {
    if (h) |p| results.sweepClose(@ptrCast(@alignCast(p)));
}

export fn f2d_sweep_worker(h: ?*anyopaque) ?*anyopaque {
    const base: *results.SweepBase = @ptrCast(@alignCast(h orelse return null));
    return results.sweepWorkerNew(gpa, base) catch null;
}

export fn f2d_sweep_worker_free(w: ?*anyopaque) void {
    if (w) |p| results.sweepWorkerFree(@ptrCast(@alignCast(p)));
}

/// Solves one variant with beam I scaled by `scale`; out2 = {roof_drift_W, max_abs_M}. Returns 0 or the error ABI code.
export fn f2d_sweep_run(w: ?*anyopaque, scale: f64, out2: *[2]f64, err: [*]u8, err_cap: c_int) c_int {
    const worker: *results.SweepWorker = @ptrCast(@alignCast(w orelse return rc_oom));
    var d = model.Diag{};
    const pt = results.sweepRun(worker, scale, &d) catch |e| {
        if (e == error.OutOfMemory) return rc_oom;
        const text = std.fmt.bufPrint(err[0..@intCast(@max(err_cap - 1, 0))], "{s}", .{d.detail()}) catch "";
        err[text.len] = 0;
        return d.code.abi();
    };
    out2.* = .{ pt.drift, pt.max_m };
    return 0;
}

/// Name of an error ABI code (the negative integers of Code.abi()); "internal" for anything else. Go maps sweep
/// error codes through this so the table lives only in model.zig.
export fn f2d_code_name(code: c_int) [*:0]const u8 {
    for (std.enums.values(model.Code)) |c| if (c.abi() == code) return @tagName(c).ptr;
    return "internal";
}

comptime {
    // keep the CLI/server surface and the session surface from being dropped by the linker
    _ = &f2d_noop;
}
