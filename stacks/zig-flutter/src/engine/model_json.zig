//! Model JSON <-> Model (SPEC 5.1). Parsing validates references and ids (invalid_ref, duplicate_id).
const std = @import("std");
const model = @import("model.zig");
const Model = model.Model;
const Diag = model.Diag;

const RawMaterial = struct { id: []const u8, E: f64 };
const RawSection = struct { id: []const u8, A: f64, I: f64 };
const RawNode = struct { id: i32, x: f64, y: f64 };
const RawSupport = struct { node: i32, ux: bool = false, uy: bool = false, rz: bool = false };
const RawMember = struct { id: i32, i: i32, j: i32, material: []const u8, section: []const u8 };
const RawNodal = struct { node: i32, fx: f64 = 0, fy: f64 = 0, mz: f64 = 0 };
const RawUdl = struct { member: i32, w: f64 = 0 };
const RawCase = struct { id: []const u8, nodal: []RawNodal = &.{}, member_udl: []RawUdl = &.{} };
const RawModel = struct {
    materials: []RawMaterial = &.{},
    sections: []RawSection = &.{},
    nodes: []RawNode = &.{},
    supports: []RawSupport = &.{},
    members: []RawMember = &.{},
    load_cases: []RawCase = &.{},
};

fn lessNode(_: void, a: model.Node, b: model.Node) bool {
    return a.id < b.id;
}

const RawMemberIdx = struct { id: i32, i: u32, j: u32, mat: u32, sec: u32 };
fn lessMember(_: void, a: RawMemberIdx, b: RawMemberIdx) bool {
    return a.id < b.id;
}

/// Parse and validate. The returned Model owns an arena built on `gpa`.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8, diag: *Diag) error{ Model, OutOfMemory }!Model {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const raw = std.json.parseFromSliceLeaky(RawModel, scratch.allocator(), bytes, json_options) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return diag.set(.invalid_json, "cannot parse model JSON: {s}", .{@errorName(e)}),
    };
    return build(gpa, raw, diag);
}

/// Same as `parse` for a model that is already a JSON value tree (e.g. nested in a sweep request).
pub fn parseValue(gpa: std.mem.Allocator, value: std.json.Value, diag: *Diag) error{ Model, OutOfMemory }!Model {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const raw = std.json.parseFromValueLeaky(RawModel, scratch.allocator(), value, json_options) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return diag.set(.invalid_json, "cannot read model JSON: {s}", .{@errorName(e)}),
    };
    return build(gpa, raw, diag);
}

const json_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed };

fn build(gpa: std.mem.Allocator, raw: RawModel, diag: *Diag) error{ Model, OutOfMemory }!Model {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const materials = try a.alloc(model.Material, raw.materials.len);
    for (raw.materials, 0..) |m, k| materials[k] = .{ .id = try a.dupe(u8, m.id), .E = m.E };
    const sections = try a.alloc(model.Section, raw.sections.len);
    for (raw.sections, 0..) |s, k| sections[k] = .{ .id = try a.dupe(u8, s.id), .A = s.A, .I = s.I };

    const nodes = try a.alloc(model.Node, raw.nodes.len);
    for (raw.nodes, 0..) |n, k| nodes[k] = .{ .id = n.id, .x = n.x, .y = n.y };
    std.mem.sort(model.Node, nodes, {}, lessNode);
    for (nodes[1..], 1..) |n, k| {
        if (n.id == nodes[k - 1].id) return diag.set(.duplicate_id, "duplicate node id {d}", .{n.id});
    }

    const tmp = try a.alloc(RawMemberIdx, raw.members.len);
    defer a.free(tmp);
    for (raw.members, 0..) |m, k| {
        const ni = indexOf(model.Node, nodes, m.i) orelse
            return diag.set(.invalid_ref, "member {d} references missing node {d}", .{ m.id, m.i });
        const nj = indexOf(model.Node, nodes, m.j) orelse
            return diag.set(.invalid_ref, "member {d} references missing node {d}", .{ m.id, m.j });
        const mat = findId(model.Material, materials, m.material) orelse
            return diag.set(.invalid_ref, "member {d} references missing material {s}", .{ m.id, m.material });
        const sec = findId(model.Section, sections, m.section) orelse
            return diag.set(.invalid_ref, "member {d} references missing section {s}", .{ m.id, m.section });
        tmp[k] = .{ .id = m.id, .i = ni, .j = nj, .mat = mat, .sec = sec };
    }
    std.mem.sort(RawMemberIdx, tmp, {}, lessMember);
    const members = try a.alloc(model.Member, tmp.len);
    for (tmp, 0..) |m, k| {
        if (k > 0 and m.id == tmp[k - 1].id) return diag.set(.duplicate_id, "duplicate member id {d}", .{m.id});
        members[k] = .{ .id = m.id, .i = m.i, .j = m.j, .mat = m.mat, .sec = m.sec };
    }

    const restraint = try a.alloc(u8, nodes.len);
    @memset(restraint, 0);
    for (raw.supports) |s| {
        const ni = indexOf(model.Node, nodes, s.node) orelse
            return diag.set(.invalid_ref, "support references missing node {d}", .{s.node});
        if (s.ux) restraint[ni] |= model.UX;
        if (s.uy) restraint[ni] |= model.UY;
        if (s.rz) restraint[ni] |= model.RZ;
    }

    const cases = try a.alloc(model.LoadCase, raw.load_cases.len);
    for (raw.load_cases, 0..) |c, k| {
        const nodal = try a.alloc(model.NodalLoad, c.nodal.len);
        for (c.nodal, 0..) |l, q| {
            const ni = indexOf(model.Node, nodes, l.node) orelse
                return diag.set(.invalid_ref, "load case {s} references missing node {d}", .{ c.id, l.node });
            nodal[q] = .{ .node = ni, .fx = l.fx, .fy = l.fy, .mz = l.mz };
        }
        const udl = try a.alloc(model.UdlLoad, c.member_udl.len);
        for (c.member_udl, 0..) |l, q| {
            const mi = indexOf(model.Member, members, l.member) orelse
                return diag.set(.invalid_ref, "load case {s} references missing member {d}", .{ c.id, l.member });
            udl[q] = .{ .member = mi, .w = l.w };
        }
        cases[k] = .{ .id = try a.dupe(u8, c.id), .nodal = nodal, .udl = udl };
    }

    return .{
        .arena = arena,
        .materials = materials,
        .sections = sections,
        .nodes = nodes,
        .members = members,
        .restraint = restraint,
        .load_cases = cases,
    };
}

fn indexOf(comptime T: type, items: []const T, id: i32) ?u32 {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid].id < id) lo = mid + 1 else hi = mid;
    }
    if (lo < items.len and items[lo].id == id) return @intCast(lo);
    return null;
}

fn findId(comptime T: type, items: []const T, id: []const u8) ?u32 {
    for (items, 0..) |it, k| if (std.mem.eql(u8, it.id, id)) return @intCast(k);
    return null;
}

/// Shortest round-trip float formatting that stays valid JSON.
pub fn writeNum(w: *std.Io.Writer, v: f64) std.Io.Writer.Error!void {
    if (!std.math.isFinite(v)) return w.writeAll("null");
    if (v == 0) return w.writeAll("0");
    const av = @abs(v);
    if (av >= 1e-5 and av < 1e16) return w.print("{d}", .{v});
    return w.print("{e}", .{v});
}

pub fn writeModel(w: *std.Io.Writer, m: *const Model) std.Io.Writer.Error!void {
    try w.writeAll("{\"materials\":[");
    for (m.materials, 0..) |x, k| {
        if (k > 0) try w.writeByte(',');
        try w.print("{{\"id\":\"{s}\",\"E\":", .{x.id});
        try writeNum(w, x.E);
        try w.writeByte('}');
    }
    try w.writeAll("],\"sections\":[");
    for (m.sections, 0..) |x, k| {
        if (k > 0) try w.writeByte(',');
        try w.print("{{\"id\":\"{s}\",\"A\":", .{x.id});
        try writeNum(w, x.A);
        try w.writeAll(",\"I\":");
        try writeNum(w, x.I);
        try w.writeByte('}');
    }
    try w.writeAll("],\"nodes\":[");
    for (m.nodes, 0..) |x, k| {
        if (k > 0) try w.writeByte(',');
        try w.print("{{\"id\":{d},\"x\":", .{x.id});
        try writeNum(w, x.x);
        try w.writeAll(",\"y\":");
        try writeNum(w, x.y);
        try w.writeByte('}');
    }
    try w.writeAll("],\"supports\":[");
    var first = true;
    for (m.nodes, m.restraint) |n, r| {
        if (r == 0) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("{{\"node\":{d},\"ux\":{},\"uy\":{},\"rz\":{}}}", .{
            n.id, r & model.UX != 0, r & model.UY != 0, r & model.RZ != 0,
        });
    }
    try w.writeAll("],\"members\":[");
    for (m.members, 0..) |x, k| {
        if (k > 0) try w.writeByte(',');
        try w.print("{{\"id\":{d},\"i\":{d},\"j\":{d},\"material\":\"{s}\",\"section\":\"{s}\"}}", .{
            x.id, m.nodes[x.i].id, m.nodes[x.j].id, m.materials[x.mat].id, m.sections[x.sec].id,
        });
    }
    try w.writeAll("],\"load_cases\":[");
    for (m.load_cases, 0..) |c, k| {
        if (k > 0) try w.writeByte(',');
        try w.print("{{\"id\":\"{s}\",\"nodal\":[", .{c.id});
        for (c.nodal, 0..) |l, q| {
            if (q > 0) try w.writeByte(',');
            try w.print("{{\"node\":{d},\"fx\":", .{m.nodes[l.node].id});
            try writeNum(w, l.fx);
            try w.writeAll(",\"fy\":");
            try writeNum(w, l.fy);
            try w.writeAll(",\"mz\":");
            try writeNum(w, l.mz);
            try w.writeByte('}');
        }
        try w.writeAll("],\"member_udl\":[");
        for (c.udl, 0..) |l, q| {
            if (q > 0) try w.writeByte(',');
            try w.print("{{\"member\":{d},\"w\":", .{m.members[l.member].id});
            try writeNum(w, l.w);
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");
}
