//! C ABI of the engine for the Flutter client. The same file is compiled to a native shared library
//! (dart:ffi on desktop) and to wasm32-freestanding (dart:js_interop on web).
//!
//! The library holds one session: a model plus the last solve. Dart never parses JSON or does any maths;
//! it reads flat arrays (zero-copy views over library memory) and calls f2d_solve after editing a node.
//! All pointers returned stay valid until the next call that reloads or regenerates the model.
const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");

const gpa: std.mem.Allocator = if (builtin.cpu.arch.isWasm()) std.heap.wasm_allocator else std.heap.smp_allocator;

/// Everything derived from the loaded model that Dart reads directly.
const Session = struct {
    model: engine.Model,
    solver: engine.Solver,
    node_ids: []i32,
    node_xy: []f64,
    member_ids: []i32,
    member_ends: []u32,
    member_len: []f64,
};

var session: ?Session = null;
var diag: engine.Diag = .{};
var scratch: std.ArrayList(u8) = .empty;
var echo_buf: []f64 = &.{};
var stats_buf: [8]f64 = @splat(0);
var last_error: [200]u8 = undefined;
var last_error_len: usize = 0;

const ok: i32 = 0;
const err_model: i32 = 1;
const err_oom: i32 = 2;
const err_state: i32 = 3;

fn dropSession() void {
    if (session) |*s| {
        s.solver.deinit();
        gpa.free(s.node_ids);
        gpa.free(s.node_xy);
        gpa.free(s.member_ids);
        gpa.free(s.member_ends);
        gpa.free(s.member_len);
        s.model.deinit();
    }
    session = null;
}

fn adopt(m: engine.Model) i32 {
    dropSession();
    var s: Session = .{
        .model = m,
        .solver = engine.Solver.init(gpa),
        .node_ids = undefined,
        .node_xy = undefined,
        .member_ids = undefined,
        .member_ends = undefined,
        .member_len = undefined,
    };
    const nn = m.nodes.len;
    const nm = m.members.len;
    s.node_ids = gpa.alloc(i32, nn) catch return oom(&s.model);
    s.node_xy = gpa.alloc(f64, nn * 2) catch return oom(&s.model);
    s.member_ids = gpa.alloc(i32, nm) catch return oom(&s.model);
    s.member_ends = gpa.alloc(u32, nm * 2) catch return oom(&s.model);
    s.member_len = gpa.alloc(f64, nm) catch return oom(&s.model);
    for (m.nodes, 0..) |n, k| {
        s.node_ids[k] = n.id;
        s.node_xy[k * 2] = n.x;
        s.node_xy[k * 2 + 1] = n.y;
    }
    for (m.members, 0..) |mem, k| {
        s.member_ids[k] = mem.id;
        s.member_ends[k * 2] = mem.i;
        s.member_ends[k * 2 + 1] = mem.j;
        s.member_len[k] = s.model.memberLength(k);
    }
    session = s;
    return ok;
}

fn oom(m: *engine.Model) i32 {
    m.deinit();
    return err_oom;
}

fn fail(e: error{ Model, OutOfMemory }) i32 {
    switch (e) {
        error.OutOfMemory => return err_oom,
        error.Model => {
            const text = std.fmt.bufPrint(&last_error, "{s}: {s}", .{ @tagName(diag.code), diag.detail() }) catch last_error[0..0];
            last_error_len = text.len;
            return err_model;
        },
    }
}

// ---- boundary probes (SPEC 5.5 boundary mode) ----

export fn f2d_noop() void {}

/// Returns a buffer of n f64 values (the payload shape of a 50x50 result set).
export fn f2d_echo(n: u32) [*]f64 {
    if (echo_buf.len < n) {
        gpa.free(echo_buf);
        echo_buf = gpa.alloc(f64, n) catch return @ptrCast(&stats_buf);
    }
    for (echo_buf[0..n], 0..) |*v, k| v.* = @floatFromInt(k);
    return echo_buf.ptr;
}

// ---- memory for passing input in ----

export fn f2d_alloc(n: usize) ?[*]u8 {
    const buf = gpa.alloc(u8, n) catch return null;
    return buf.ptr;
}

export fn f2d_free(p: [*]u8, n: usize) void {
    gpa.free(p[0..n]);
}

// ---- model lifecycle ----

export fn f2d_load_json(ptr: [*]const u8, len: usize) i32 {
    const m = engine.model_json.parse(gpa, ptr[0..len], &diag) catch |e| return fail(e);
    return adopt(m);
}

export fn f2d_generate(bays: u32, stories: u32) i32 {
    const m = engine.gen.generate(gpa, bays, stories) catch return err_oom;
    return adopt(m);
}

export fn f2d_error_ptr() [*]const u8 {
    return &last_error;
}

export fn f2d_error_len() usize {
    return last_error_len;
}

// ---- geometry (read directly by Dart) ----

export fn f2d_node_count() u32 {
    return if (session) |s| @intCast(s.model.nodes.len) else 0;
}

export fn f2d_member_count() u32 {
    return if (session) |s| @intCast(s.model.members.len) else 0;
}

export fn f2d_case_count() u32 {
    return if (session) |s| @intCast(s.model.load_cases.len) else 0;
}

export fn f2d_node_ids() [*]const i32 {
    return session.?.node_ids.ptr;
}

/// x0, y0, x1, y1, ...
export fn f2d_node_xy() [*]const f64 {
    return session.?.node_xy.ptr;
}

/// One bit mask per node: 1 = ux, 2 = uy, 4 = rz restrained.
export fn f2d_node_restraint() [*]const u8 {
    return session.?.model.restraint.ptr;
}

export fn f2d_member_ids() [*]const i32 {
    return session.?.member_ids.ptr;
}

/// i0, j0, i1, j1, ... as node indices.
export fn f2d_member_ends() [*]const u32 {
    return session.?.member_ends.ptr;
}

export fn f2d_member_len() [*]const f64 {
    return session.?.member_len.ptr;
}

export fn f2d_case_name_ptr(k: u32) [*]const u8 {
    return session.?.model.load_cases[k].id.ptr;
}

export fn f2d_case_name_len(k: u32) usize {
    return session.?.model.load_cases[k].id.len;
}

/// Move one node (index, not id). Topology is unchanged, so the factor plan is reused by the next solve.
export fn f2d_set_node_xy(idx: u32, x: f64, y: f64) void {
    const s = &(session orelse return);
    s.model.nodes[idx].x = x;
    s.model.nodes[idx].y = y;
    s.node_xy[idx * 2] = x;
    s.node_xy[idx * 2 + 1] = y;
    for (s.model.members, 0..) |mem, k| {
        if (mem.i == idx or mem.j == idx) s.member_len[k] = s.model.memberLength(k);
    }
}

// ---- solving ----

/// Solve the load cases whose bit is set in `mask`. Returns 0 on success.
export fn f2d_solve(mask: u32) i32 {
    const s = &(session orelse return err_state);
    s.solver.solve(&s.model, s.model.sections, mask, &diag) catch |e| return fail(e);
    const st = s.solver.stats;
    stats_buf = .{
        st.assemble_ms,
        st.factor_ms,
        st.solve_ms,
        @floatFromInt(st.free_dofs),
        @floatFromInt(st.profile_before),
        @floatFromInt(st.profile_after),
        0,
        0,
    };
    return ok;
}

/// assemble_ms, factor_ms, solve_ms, free_dofs, profile_before, profile_after.
export fn f2d_stats() [*]const f64 {
    return &stats_buf;
}

fn solvedCase(k: u32) ?*const engine.solver.CaseResult {
    const s = &(session orelse return null);
    if (k >= s.solver.cases.len or !s.solver.cases[k].solved) return null;
    return &s.solver.cases[k];
}

/// nodes*3 displacements (ux, uy, rz); null pointer when the case has not been solved.
export fn f2d_disp(k: u32) ?[*]const f64 {
    return (solvedCase(k) orelse return null).disp.ptr;
}

export fn f2d_reactions(k: u32) ?[*]const f64 {
    return (solvedCase(k) orelse return null).reactions.ptr;
}

/// members*6 local end forces.
export fn f2d_end_forces(k: u32) ?[*]const f64 {
    return (solvedCase(k) orelse return null).end_forces.ptr;
}

/// members: max |M| over the member's stations.
export fn f2d_max_m(k: u32) ?[*]const f64 {
    return (solvedCase(k) orelse return null).max_m.ptr;
}

/// members*11 bending moments at the stations x = 0, L/10, ..., L.
export fn f2d_stations_m(k: u32) ?[*]const f64 {
    return (solvedCase(k) orelse return null).m_stations.ptr;
}

export fn f2d_residual(k: u32) f64 {
    return (solvedCase(k) orelse return 0).residual;
}

// ---- JSON out (save model / export results) ----

/// Serialize into the scratch buffer; returns its length (0 on failure). Read it with f2d_out_ptr.
export fn f2d_export_model() usize {
    const s = &(session orelse return 0);
    scratch.clearRetainingCapacity();
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &scratch);
    engine.model_json.writeModel(&aw.writer, &s.model) catch {
        scratch = aw.toArrayList();
        return 0;
    };
    scratch = aw.toArrayList();
    return scratch.items.len;
}

export fn f2d_export_results() usize {
    const s = &(session orelse return 0);
    scratch.clearRetainingCapacity();
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &scratch);
    engine.results_json.writeResults(&aw.writer, &s.model, &s.solver, null) catch {
        scratch = aw.toArrayList();
        return 0;
    };
    scratch = aw.toArrayList();
    return scratch.items.len;
}

export fn f2d_out_ptr() [*]const u8 {
    return scratch.items.ptr;
}

// ---- process clock (native only; used by the startup bench) ----

const win = struct {
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
    extern "kernel32" fn GetProcessTimes(h: *anyopaque, created: *u64, exited: *u64, kernel: *u64, user: *u64) callconv(.winapi) i32;
    extern "kernel32" fn GetSystemTimeAsFileTime(ft: *u64) callconv(.winapi) void;
};

/// Milliseconds since this process was created, or -1 when the platform has no cheap answer.
export fn f2d_process_uptime_ms() f64 {
    if (comptime builtin.os.tag == .windows) {
        var created: u64 = 0;
        var other: [3]u64 = undefined;
        if (win.GetProcessTimes(win.GetCurrentProcess(), &created, &other[0], &other[1], &other[2]) == 0) return -1;
        var now: u64 = 0;
        win.GetSystemTimeAsFileTime(&now);
        return @as(f64, @floatFromInt(now - created)) / 10000.0;
    } else {
        return -1;
    }
}
