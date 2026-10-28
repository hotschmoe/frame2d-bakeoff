//! Unit tests (run with `zig test src/tests.zig`; see test_all in stack.sh).
const std = @import("std");
const testing = std.testing;
const engine = @import("engine.zig");
const model = @import("model.zig");
const results = @import("results.zig");
const session = @import("session.zig");
const util = @import("util.zig");
const json = @import("json.zig");

const gpa = testing.allocator;

const cantilever =
    \\{"materials":[{"id":"s","E":200e9}],"sections":[{"id":"b","A":0.01,"I":8e-5}],
    \\ "nodes":[{"id":1,"x":0,"y":0},{"id":2,"x":5,"y":0}],
    \\ "supports":[{"node":1,"ux":true,"uy":true,"rz":true}],
    \\ "members":[{"id":1,"i":1,"j":2,"material":"s","section":"b"}],
    \\ "load_cases":[{"id":"P","nodal":[{"node":2,"fy":-10000}],"member_udl":[]}]}
;

fn solveText(a: std.mem.Allocator, text: []const u8, d: *model.Diag) model.Error!struct { p: *engine.Prepared, outs: []engine.CaseOut } {
    const m = try model.parseModel(a, text, d);
    const p = try engine.prepare(gpa, &m, d);
    errdefer p.deinit();
    const outs = try a.alloc(engine.CaseOut, p.cases.len);
    for (outs) |*o| o.* = try engine.CaseOut.alloc(a, p);
    var st: engine.Stats = undefined;
    try engine.solve(p, null, outs, &st, d);
    return .{ .p = p, .outs = outs };
}

test "cantilever tip load (F01)" {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    var d = model.Diag{};
    const r = try solveText(ar.allocator(), cantilever, &d);
    defer r.p.deinit();
    const u = r.outs[0].u;
    try testing.expectApproxEqAbs(-0.026041666666666668, u[4], 1e-12);
    try testing.expectApproxEqAbs(-0.0078125, u[5], 1e-12);
    try testing.expectApproxEqAbs(10000.0, r.outs[0].react[1], 1e-6);
    try testing.expectApproxEqAbs(50000.0, r.outs[0].react[2], 1e-6);
}

test "gen 10x10 profiles match the reference" {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const a = ar.allocator();
    var d = model.Diag{};
    const m = try model.gen(a, 10, 10);
    const p = try engine.prepare(gpa, &m, &d);
    defer p.deinit();
    const outs = try a.alloc(engine.CaseOut, 3);
    for (outs) |*o| o.* = try engine.CaseOut.alloc(a, p);
    var st: engine.Stats = undefined;
    try engine.solve(p, null, outs, &st, &d);
    try testing.expectEqual(@as(usize, 330), st.free_dofs);
    try testing.expectEqual(@as(usize, 10221), st.profile_before);
    try testing.expectEqual(@as(usize, 7575), st.profile_after);
    for (outs) |o| try testing.expect(o.residual < 1e-8);
}

fn expectCode(text: []const u8, code: model.Code) !void {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    var d = model.Diag{};
    if (solveText(ar.allocator(), text, &d)) |r| {
        r.p.deinit();
        return error.TestExpectedError;
    } else |_| {}
    try testing.expectEqual(code, d.code);
}

test "model errors" {
    // no supports -> unstable
    try expectCode(
        \\{"materials":[{"id":"s","E":2e11}],"sections":[{"id":"b","A":0.01,"I":8e-5}],"nodes":[{"id":1,"x":0,"y":0},{"id":2,"x":5,"y":0}],
        \\ "members":[{"id":1,"i":1,"j":2,"material":"s","section":"b"}],"load_cases":[{"id":"P"}]}
    , .unstable);
    // missing node
    try expectCode(
        \\{"materials":[{"id":"s","E":2e11}],"sections":[{"id":"b","A":0.01,"I":8e-5}],"nodes":[{"id":1,"x":0,"y":0}],
        \\ "supports":[{"node":1,"ux":true}],"members":[{"id":1,"i":1,"j":99,"material":"s","section":"b"}],"load_cases":[]}
    , .invalid_ref);
    // zero length
    try expectCode(
        \\{"materials":[{"id":"s","E":2e11}],"sections":[{"id":"b","A":0.01,"I":8e-5}],"nodes":[{"id":1,"x":0,"y":0},{"id":2,"x":0,"y":0}],
        \\ "supports":[{"node":1,"ux":true,"uy":true,"rz":true}],"members":[{"id":1,"i":1,"j":2,"material":"s","section":"b"}],"load_cases":[]}
    , .zero_length);
    // duplicate node
    try expectCode(
        \\{"materials":[],"sections":[],"nodes":[{"id":1,"x":0,"y":0},{"id":1,"x":1,"y":0}],"members":[],"load_cases":[]}
    , .duplicate_id);
    // every DOF restrained
    try expectCode(
        \\{"materials":[],"sections":[],"nodes":[{"id":1,"x":0,"y":0}],"supports":[{"node":1,"ux":true,"uy":true,"rz":true}],"members":[],"load_cases":[]}
    , .no_free_dofs);
    // restrained and sprung
    try expectCode(
        \\{"materials":[],"sections":[],"nodes":[{"id":1,"x":0,"y":0}],"supports":[{"node":1,"uy":true}],"springs":[{"node":1,"ky":5}],"members":[],"load_cases":[]}
    , .support_conflict);
    // malformed JSON
    try expectCode("{\"nodes\":[", .bad_request);
}

test "sweep endpoints: stiffer beams reduce drift" {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const a = ar.allocator();
    var d = model.Diag{};
    const m = try model.gen(a, 3, 3);
    var b = util.Buf{ .a = a };
    try model.writeModel(&b, &m);
    const base = try results.sweepOpen(gpa, b.slice(), &d);
    defer results.sweepClose(base);
    const w = try results.sweepWorkerNew(gpa, base);
    defer results.sweepWorkerFree(w);
    const soft = try results.sweepRun(w, 0.5, &d);
    const stiff = try results.sweepRun(w, 2.0, &d);
    try testing.expect(soft.drift > stiff.drift);
    try testing.expect(soft.max_m > 0);
}

test "session: gen, solve, move a node" {
    var d = model.Diag{};
    var ar = std.heap.ArenaAllocator.init(gpa);
    const m = try model.gen(ar.allocator(), 2, 2);
    const s = try session.create(ar, m, &d);
    defer session.destroy(s);
    try testing.expectEqual([3]i32{ 9, 10, 3 }, s.counts());
    try s.solve(0, &d);
    try testing.expectEqual(@as(f64, 18), s.stats[0]);
    try testing.expect(s.stats[6] < 1e-8);
    const base = try gpa.dupe(f64, s.res);
    defer gpa.free(base);
    s.setNode(8, 12.5, 7.5);
    try s.solve(0, &d);
    var changed = false;
    for (base, s.res) |x, y| if (@abs(x - y) > 1e-12) {
        changed = true;
    };
    try testing.expect(changed);
    const out = try s.toJson();
    try testing.expect(std.mem.indexOf(u8, out, "12.5") != null or std.mem.indexOf(u8, out, "1.25e1") != null);
}

test "json numbers round trip" {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    var b = util.Buf{ .a = ar.allocator() };
    const vals = [_]f64{ 0, -0.0, 1, 0.1, 1.0 / 3.0, 1e-300, 1.7976931348623157e308, -2.5e-9, 123456.789 };
    for (vals) |v| {
        b.list.len = 0;
        try b.num(v);
        const back = try std.fmt.parseFloat(f64, b.slice());
        try testing.expectEqual(v, back);
    }
    const v = try json.parse(ar.allocator(), "{\"a\":[1,2,{\"b\":\"x\\u0041\\n\"}],\"c\":null}");
    try testing.expectEqualStrings("xA\n", v.get("a").?.arr[2].get("b").?.str);
}

// ---- P2: springs, releases, auto-restraint (closed forms; E = 200e9, I = 8e-5, A = 0.01, L = 5)

test "spring: tip uy spring in parallel with the cantilever (3EI/L^3)" {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    var d = model.Diag{};
    const r = try solveText(ar.allocator(),
        \\{"materials":[{"id":"s","E":200e9}],"sections":[{"id":"b","A":0.01,"I":8e-5}],
            \\ "nodes":[{"id":1,"x":0,"y":0},{"id":2,"x":5,"y":0}],
            \\ "supports":[{"node":1,"ux":true,"uy":true,"rz":true}],
            \\ "springs":[{"node":2,"ky":100000}],
            \\ "members":[{"id":1,"i":1,"j":2,"material":"s","section":"b"}],
            \\ "load_cases":[{"id":"P","nodal":[{"node":2,"fy":-10000}],"member_udl":[]}]}
    , &d);
    defer r.p.deinit();
    const k_beam = 3.0 * 200e9 * 8e-5 / 125.0; // 384000 N/m
    try testing.expectApproxEqAbs(-10000.0 / (k_beam + 100000.0), r.outs[0].u[4], 1e-12);
    // the support carries only what the spring does not: V = P * k_beam / (k_beam + k)
    try testing.expectApproxEqAbs(10000.0 * k_beam / (k_beam + 100000.0), r.outs[0].react[1], 1e-6);
    try testing.expect(r.outs[0].residual < 1e-9);
}

test "spring: axial spring in parallel with EA/L" {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    var d = model.Diag{};
    const r = try solveText(ar.allocator(),
        \\{"materials":[{"id":"s","E":200e9}],"sections":[{"id":"b","A":0.01,"I":8e-5}],
            \\ "nodes":[{"id":1,"x":0,"y":0},{"id":2,"x":5,"y":0}],
            \\ "supports":[{"node":1,"ux":true,"uy":true,"rz":true}],
            \\ "springs":[{"node":2,"kx":1e8}],
            \\ "members":[{"id":1,"i":1,"j":2,"material":"s","section":"b"}],
            \\ "load_cases":[{"id":"P","nodal":[{"node":2,"fx":1000}],"member_udl":[]}]}
    , &d);
    defer r.p.deinit();
    try testing.expectApproxEqAbs(1000.0 / (200e9 * 0.01 / 5.0 + 1e8), r.outs[0].u[3], 1e-15);
}

test "release: fixed-pinned beam under UDL, and the pinned end is auto-restrained with a warning" {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    var d = model.Diag{};
    const r = try solveText(ar.allocator(),
        \\{"materials":[{"id":"s","E":200e9}],"sections":[{"id":"b","A":0.01,"I":8e-5}],
            \\ "nodes":[{"id":1,"x":0,"y":0},{"id":2,"x":5,"y":0}],
            \\ "supports":[{"node":1,"ux":true,"uy":true,"rz":true},{"node":2,"uy":true}],
            \\ "members":[{"id":1,"i":1,"j":2,"material":"s","section":"b","release":{"i":[],"j":["mz"]}}],
            \\ "load_cases":[{"id":"W","nodal":[],"member_udl":[{"member":1,"w":-10000}]}]}
    , &d);
    defer r.p.deinit();
    // node 2's rz would be a singular free DOF (only a released member attaches to it): restrained, with a warning
    try testing.expectEqual(@as(usize, 1), r.p.warns.len);
    try testing.expectEqual(@as(i64, 2), r.p.warns[0]);
    const w = 10000.0;
    try testing.expectApproxEqAbs(5.0 * w * 5.0 / 8.0, r.outs[0].react[1], 1e-6); // fixed end shear 5wL/8
    try testing.expectApproxEqAbs(w * 25.0 / 8.0, r.outs[0].react[2], 1e-6); // fixed end moment wL^2/8
    try testing.expectApproxEqAbs(3.0 * w * 5.0 / 8.0, r.outs[0].react[4], 1e-6); // pinned end 3wL/8
    try testing.expectApproxEqAbs(0.0, r.outs[0].ef[5], 1e-6); // released end carries no moment
    try testing.expect(r.outs[0].residual < 1e-9);
}

test "release: a mechanism (both ends released, free node) is unstable" {
    try expectCode(
        \\{"materials":[{"id":"s","E":200e9}],"sections":[{"id":"b","A":0.01,"I":8e-5}],
            \\ "nodes":[{"id":1,"x":0,"y":0},{"id":2,"x":5,"y":0}],
            \\ "supports":[{"node":1,"ux":true,"uy":true,"rz":true}],
            \\ "members":[{"id":1,"i":1,"j":2,"material":"s","section":"b","release":{"i":["mz"],"j":["mz"]}}],
            \\ "load_cases":[{"id":"P","nodal":[{"node":2,"fy":-1}],"member_udl":[]}]}
    , .unstable);
}

test "check_json style validation: prepare rejects a bad load reference that parsing accepts" {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    var d = model.Diag{};
    const m = try model.parseModel(ar.allocator(),
        \\{"materials":[{"id":"s","E":200e9}],"sections":[{"id":"b","A":0.01,"I":8e-5}],
            \\ "nodes":[{"id":1,"x":0,"y":0}],"supports":[{"node":1,"ux":true,"uy":true,"rz":true}],"members":[],
            \\ "load_cases":[{"id":"P","nodal":[{"node":42,"fy":-1}],"member_udl":[]}]}
    , &d);
    try testing.expectError(error.Model, engine.prepare(gpa, &m, &d));
    try testing.expectEqual(model.Code.invalid_ref, d.code);
}

test "session: out-of-range case index is an error; no load cases solves to zeros" {
    var d = model.Diag{};
    var ar = std.heap.ArenaAllocator.init(gpa);
    const m = try model.gen(ar.allocator(), 2, 2);
    const s = try session.create(ar, m, &d);
    defer session.destroy(s);
    try testing.expectError(error.Model, s.solve(3, &d));
    try testing.expectEqual(model.Code.invalid_ref, d.code);
    try testing.expectError(error.Model, s.solve(-1, &d));

    var ar2 = std.heap.ArenaAllocator.init(gpa);
    const m2 = try model.parseModel(ar2.allocator(),
        \\{"materials":[{"id":"s","E":200e9}],"sections":[{"id":"b","A":0.01,"I":8e-5}],
            \\ "nodes":[{"id":1,"x":0,"y":0},{"id":2,"x":5,"y":0}],"supports":[{"node":1,"ux":true,"uy":true,"rz":true}],
            \\ "members":[{"id":1,"i":1,"j":2,"material":"s","section":"b"}],"load_cases":[]}
    , &d);
    const s2 = try session.create(ar2, m2, &d);
    defer session.destroy(s2);
    try s2.solve(0, &d);
    for (s2.res) |v| try testing.expectEqual(@as(f64, 0), v);
}

test "release: i-end release mirrors j-end release (fixed at the released side's far end)" {
    // Same physical beam, described both ways: pinned at the left / fixed at the right, and the mirror image.
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    var d = model.Diag{};
    const a = try solveText(ar.allocator(),
        \\{"materials":[{"id":"s","E":200e9}],"sections":[{"id":"b","A":0.01,"I":8e-5}],
        \\ "nodes":[{"id":1,"x":0,"y":0},{"id":2,"x":5,"y":0}],
        \\ "supports":[{"node":1,"uy":true},{"node":2,"ux":true,"uy":true,"rz":true}],
        \\ "members":[{"id":1,"i":1,"j":2,"material":"s","section":"b","release":{"i":["mz"],"j":[]}}],
        \\ "load_cases":[{"id":"W","nodal":[],"member_udl":[{"member":1,"w":-10000}]}]}
    , &d);
    defer a.p.deinit();
    const w = 10000.0;
    try testing.expectApproxEqAbs(3.0 * w * 5.0 / 8.0, a.outs[0].react[1], 1e-6); // pinned end 3wL/8
    try testing.expectApproxEqAbs(5.0 * w * 5.0 / 8.0, a.outs[0].react[4], 1e-6); // fixed end 5wL/8
    try testing.expectApproxEqAbs(-w * 25.0 / 8.0, a.outs[0].react[5], 1e-6); // fixed end moment wL^2/8 (clockwise at the right end)
    try testing.expectApproxEqAbs(0.0, a.outs[0].ef[2], 1e-6); // released i end carries no moment
    try testing.expect(a.outs[0].residual < 1e-9);
}

// ---- C ABI lifetime contract (lib.zig): what the Dart bridge relies on
const lib = @import("lib.zig");

test "abi: a freed handle stays dead after its slot is reused; double free is a no-op" {
    const h1 = lib.f2d_gen(2, 2);
    try testing.expect(h1 > 0);
    lib.f2d_free(h1);
    const h2 = lib.f2d_gen(5, 4); // reuses the slot
    defer lib.f2d_free(h2);
    try testing.expect(h2 > 0 and h2 != h1);
    var c: [3]c_int = .{ 9, 9, 9 };
    lib.f2d_counts(h1, &c);
    try testing.expectEqual([3]c_int{ 0, 0, 0 }, c);
    try testing.expect(lib.f2d_geometry(h1) == null);
    try testing.expect(lib.f2d_result(h1) == null);
    try testing.expect(lib.f2d_stats(h1) == null);
    try testing.expect(lib.f2d_solve(h1, 0) < 0);
    var n: c_int = 77;
    try testing.expect(lib.f2d_to_json(h1, &n) == null);
    try testing.expectEqual(@as(c_int, 0), n);
    lib.f2d_free(h1); // must not free h2
    try testing.expectEqual(@as(c_int, 0), lib.f2d_solve(h2, 0));
    lib.f2d_counts(h2, &c);
    try testing.expectEqual([3]c_int{ 30, 44, 3 }, c);
    for ([_]c_int{ 0, -1, 1 << 30 }) |bad| try testing.expect(lib.f2d_result(bad) == null);
}

test "abi: session buffers are stable across solve, set_node, to_json and other sessions" {
    const h = lib.f2d_gen(10, 10);
    defer lib.f2d_free(h);
    const geo = lib.f2d_geometry(h).?;
    const res = lib.f2d_result(h).?;
    const st = lib.f2d_stats(h).?;
    try testing.expectEqual(@as(c_int, 0), lib.f2d_solve(h, 0));
    var n: c_int = 0;
    const j1 = lib.f2d_to_json(h, &n).?;
    try testing.expect(n > 100);
    _ = j1;
    const other = lib.f2d_gen(40, 40);
    try testing.expectEqual(@as(c_int, 0), lib.f2d_solve(other, 1));
    lib.f2d_free(other);
    lib.f2d_set_node(h, 5, 1.25, 2.5);
    try testing.expectEqual(@as(c_int, 0), lib.f2d_solve(h, 1));
    _ = lib.f2d_to_json(h, &n).?;
    try testing.expect(lib.f2d_geometry(h).? == geo);
    try testing.expect(lib.f2d_result(h).? == res);
    try testing.expect(lib.f2d_stats(h).? == st);
    try testing.expectEqual(@as(f64, 1.25), geo[5 * session.node_stride + 1]);
}
