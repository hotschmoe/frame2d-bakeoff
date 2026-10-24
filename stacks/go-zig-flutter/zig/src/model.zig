//! Model types (SPEC 5.1), JSON in/out, error codes (SPEC 4.6) and the generator (SPEC 4.8).
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");
const util = @import("util.zig");

pub const Material = struct { id: []const u8, E: f64 };
pub const Section = struct { id: []const u8, A: f64, I: f64 };
pub const Node = struct {
    id: i64,
    x: f64,
    y: f64,
    bench_pad: u32 = 0, // BENCH-EDIT:struct
};
pub const Support = struct { node: i64, ux: bool, uy: bool, rz: bool };
pub const Spring = struct { node: i64, kx: f64, ky: f64, kr: f64 };
/// Only `mz` releases are modelled (SPEC 4.7).
pub const Release = struct { i_mz: bool = false, j_mz: bool = false };
pub const Member = struct {
    id: i64,
    i: i64,
    j: i64,
    material: []const u8,
    section: []const u8,
    release: ?Release = null,
};
pub const NodalLoad = struct { node: i64, fx: f64, fy: f64, mz: f64 };
pub const MemberUdl = struct { member: i64, w: f64 };
pub const LoadCase = struct { id: []const u8, nodal: []NodalLoad, udl: []MemberUdl };

pub const Model = struct {
    materials: []Material = &.{},
    sections: []Section = &.{},
    nodes: []Node = &.{},
    supports: []Support = &.{},
    springs: []Spring = &.{},
    members: []Member = &.{},
    load_cases: []LoadCase = &.{},
};

pub const Code = enum {
    invalid_ref,
    zero_length,
    duplicate_id,
    unstable,
    no_free_dofs,
    support_conflict,
    bad_request,

    pub fn name(self: Code) []const u8 {
        return @tagName(self);
    }

    /// Small integers used across the C ABI (negative = failure).
    pub fn abi(self: Code) i32 {
        return switch (self) {
            .bad_request => -1,
            .invalid_ref => -2,
            .zero_length => -3,
            .duplicate_id => -4,
            .unstable => -5,
            .no_free_dofs => -6,
            .support_conflict => -7,
        };
    }
};

/// Carries the code and message of a model error out of fallible functions that return `error.Model`.
pub const Diag = struct {
    code: Code = .bad_request,
    buf: [200]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Diag, code: Code, comptime fmt: []const u8, args: anytype) error{Model} {
        self.code = code;
        const s = std.fmt.bufPrint(&self.buf, fmt, args) catch self.buf[0..self.buf.len];
        self.len = s.len;
        return error.Model;
    }

    pub fn detail(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }

    /// `{"error": "...", "detail": "..."}`
    pub fn writeJson(self: *const Diag, b: *util.Buf) Allocator.Error!void {
        try b.raw("{\"error\":");
        try b.str(self.code.name());
        try b.raw(",\"detail\":");
        try b.str(self.detail());
        try b.byte('}');
    }
};

pub const Error = error{ Model, OutOfMemory };

// ---- JSON -> Model ----

fn bad(d: *Diag, comptime what: []const u8) error{Model} {
    return d.set(.bad_request, "malformed model: " ++ what, .{});
}

fn numOr(obj: json.Value, key: []const u8, default: f64, d: *Diag) error{Model}!f64 {
    const v = obj.get(key) orelse return default;
    return switch (v) {
        .null => default,
        .num => |n| n,
        else => bad(d, "expected a number"),
    };
}

fn idOf(obj: json.Value, key: []const u8, d: *Diag) error{Model}!i64 {
    const n = try numOr(obj, key, 0, d);
    if (n != @trunc(n) or @abs(n) > 9.0e15) return bad(d, "expected an integer id");
    return @intFromFloat(n);
}

fn boolOr(obj: json.Value, key: []const u8, d: *Diag) error{Model}!bool {
    const v = obj.get(key) orelse return false;
    return switch (v) {
        .null => false,
        .bool => |b| b,
        else => bad(d, "expected a boolean"),
    };
}

fn strOf(obj: json.Value, key: []const u8, d: *Diag) error{Model}![]const u8 {
    const v = obj.get(key) orelse return "";
    return switch (v) {
        .null => "",
        .str => |s| s,
        else => bad(d, "expected a string"),
    };
}

fn arrOf(obj: json.Value, key: []const u8, d: *Diag) error{Model}![]const json.Value {
    const v = obj.get(key) orelse return &.{};
    return switch (v) {
        .null => &.{},
        .arr => |a| a,
        else => bad(d, "expected an array"),
    };
}

fn releaseFlag(list: []const json.Value) bool {
    for (list) |s| if (s == .str and std.mem.eql(u8, s.str, "mz")) return true;
    return false;
}

/// Convert a parsed JSON document into a Model. Strings point into the original text, which must outlive it.
pub fn fromJson(a: Allocator, root: json.Value, d: *Diag) Error!Model {
    if (root != .obj) return bad(d, "top level must be an object");
    var m = Model{};

    const mats = try arrOf(root, "materials", d);
    m.materials = try a.alloc(Material, mats.len);
    for (mats, 0..) |v, k| m.materials[k] = .{ .id = try strOf(v, "id", d), .E = try numOr(v, "E", 0, d) };

    const secs = try arrOf(root, "sections", d);
    m.sections = try a.alloc(Section, secs.len);
    for (secs, 0..) |v, k| m.sections[k] = .{ .id = try strOf(v, "id", d), .A = try numOr(v, "A", 0, d), .I = try numOr(v, "I", 0, d) };

    const nodes = try arrOf(root, "nodes", d);
    m.nodes = try a.alloc(Node, nodes.len);
    for (nodes, 0..) |v, k| m.nodes[k] = .{ .id = try idOf(v, "id", d), .x = try numOr(v, "x", 0, d), .y = try numOr(v, "y", 0, d) };

    const sups = try arrOf(root, "supports", d);
    m.supports = try a.alloc(Support, sups.len);
    for (sups, 0..) |v, k| m.supports[k] = .{ .node = try idOf(v, "node", d), .ux = try boolOr(v, "ux", d), .uy = try boolOr(v, "uy", d), .rz = try boolOr(v, "rz", d) };

    const sprs = try arrOf(root, "springs", d);
    m.springs = try a.alloc(Spring, sprs.len);
    for (sprs, 0..) |v, k| m.springs[k] = .{ .node = try idOf(v, "node", d), .kx = try numOr(v, "kx", 0, d), .ky = try numOr(v, "ky", 0, d), .kr = try numOr(v, "kr", 0, d) };

    const mems = try arrOf(root, "members", d);
    m.members = try a.alloc(Member, mems.len);
    for (mems, 0..) |v, k| {
        var rel: ?Release = null;
        if (v.get("release")) |r| switch (r) {
            .null => {},
            .obj => rel = .{ .i_mz = releaseFlag(try arrOf(r, "i", d)), .j_mz = releaseFlag(try arrOf(r, "j", d)) },
            else => return bad(d, "release must be an object"),
        };
        m.members[k] = .{
            .id = try idOf(v, "id", d),
            .i = try idOf(v, "i", d),
            .j = try idOf(v, "j", d),
            .material = try strOf(v, "material", d),
            .section = try strOf(v, "section", d),
            .release = rel,
        };
    }

    const lcs = try arrOf(root, "load_cases", d);
    m.load_cases = try a.alloc(LoadCase, lcs.len);
    for (lcs, 0..) |v, k| {
        const nl = try arrOf(v, "nodal", d);
        const ul = try arrOf(v, "member_udl", d);
        const nodal = try a.alloc(NodalLoad, nl.len);
        for (nl, 0..) |x, q| nodal[q] = .{ .node = try idOf(x, "node", d), .fx = try numOr(x, "fx", 0, d), .fy = try numOr(x, "fy", 0, d), .mz = try numOr(x, "mz", 0, d) };
        const udl = try a.alloc(MemberUdl, ul.len);
        for (ul, 0..) |x, q| udl[q] = .{ .member = try idOf(x, "member", d), .w = try numOr(x, "w", 0, d) };
        m.load_cases[k] = .{ .id = try strOf(v, "id", d), .nodal = nodal, .udl = udl };
    }
    return m;
}

/// Parse model JSON text. `a` should be an arena; `text` must outlive the result.
pub fn parseModel(a: Allocator, text: []const u8, d: *Diag) Error!Model {
    const root = json.parse(a, text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => return d.set(.bad_request, "invalid JSON", .{}),
    };
    return fromJson(a, root, d);
}

// ---- Model -> JSON ----

pub fn writeModel(b: *util.Buf, m: *const Model) Allocator.Error!void {
    try b.raw("{\"materials\":[");
    for (m.materials, 0..) |x, k| {
        if (k > 0) try b.byte(',');
        try b.raw("{\"id\":");
        try b.str(x.id);
        try b.raw(",\"E\":");
        try b.num(x.E);
        try b.byte('}');
    }
    try b.raw("],\"sections\":[");
    for (m.sections, 0..) |x, k| {
        if (k > 0) try b.byte(',');
        try b.raw("{\"id\":");
        try b.str(x.id);
        try b.raw(",\"A\":");
        try b.num(x.A);
        try b.raw(",\"I\":");
        try b.num(x.I);
        try b.byte('}');
    }
    try b.raw("],\"nodes\":[");
    for (m.nodes, 0..) |x, k| {
        if (k > 0) try b.byte(',');
        try b.raw("{\"id\":");
        try b.int(x.id);
        try b.raw(",\"x\":");
        try b.num(x.x);
        try b.raw(",\"y\":");
        try b.num(x.y);
        try b.byte('}');
    }
    try b.raw("],\"supports\":[");
    for (m.supports, 0..) |x, k| {
        if (k > 0) try b.byte(',');
        try b.raw("{\"node\":");
        try b.int(x.node);
        try b.raw(if (x.ux) ",\"ux\":true" else ",\"ux\":false");
        try b.raw(if (x.uy) ",\"uy\":true" else ",\"uy\":false");
        try b.raw(if (x.rz) ",\"rz\":true}" else ",\"rz\":false}");
    }
    if (m.springs.len > 0) {
        try b.raw("],\"springs\":[");
        for (m.springs, 0..) |x, k| {
            if (k > 0) try b.byte(',');
            try b.raw("{\"node\":");
            try b.int(x.node);
            try b.raw(",\"kx\":");
            try b.num(x.kx);
            try b.raw(",\"ky\":");
            try b.num(x.ky);
            try b.raw(",\"kr\":");
            try b.num(x.kr);
            try b.byte('}');
        }
    }
    try b.raw("],\"members\":[");
    for (m.members, 0..) |x, k| {
        if (k > 0) try b.byte(',');
        try b.raw("{\"id\":");
        try b.int(x.id);
        try b.raw(",\"i\":");
        try b.int(x.i);
        try b.raw(",\"j\":");
        try b.int(x.j);
        try b.raw(",\"material\":");
        try b.str(x.material);
        try b.raw(",\"section\":");
        try b.str(x.section);
        if (x.release) |r| {
            try b.raw(",\"release\":{\"i\":");
            try b.raw(if (r.i_mz) "[\"mz\"]" else "[]");
            try b.raw(",\"j\":");
            try b.raw(if (r.j_mz) "[\"mz\"]" else "[]");
            try b.byte('}');
        }
        try b.byte('}');
    }
    try b.raw("],\"load_cases\":[");
    for (m.load_cases, 0..) |lc, k| {
        if (k > 0) try b.byte(',');
        try b.raw("{\"id\":");
        try b.str(lc.id);
        try b.raw(",\"nodal\":[");
        for (lc.nodal, 0..) |x, q| {
            if (q > 0) try b.byte(',');
            try b.raw("{\"node\":");
            try b.int(x.node);
            try b.raw(",\"fx\":");
            try b.num(x.fx);
            try b.raw(",\"fy\":");
            try b.num(x.fy);
            try b.raw(",\"mz\":");
            try b.num(x.mz);
            try b.byte('}');
        }
        try b.raw("],\"member_udl\":[");
        for (lc.udl, 0..) |x, q| {
            if (q > 0) try b.byte(',');
            try b.raw("{\"member\":");
            try b.int(x.member);
            try b.raw(",\"w\":");
            try b.num(x.w);
            try b.byte('}');
        }
        try b.raw("]}");
    }
    try b.raw("]}");
}

// ---- generator (SPEC 4.8) ----

pub fn gen(a: Allocator, bays: usize, stories: usize) Allocator.Error!Model {
    const bay_w = 6.0;
    const story_h = 3.5;
    const nb = bays + 1;
    var m = Model{};
    m.materials = try a.dupe(Material, &.{.{ .id = "steel", .E = 200e9 }});
    m.sections = try a.dupe(Section, &.{ .{ .id = "COL", .A = 0.015, .I = 1.2e-4 }, .{ .id = "BM", .A = 0.010, .I = 8.0e-5 } });
    m.nodes = try a.alloc(Node, nb * (stories + 1));
    for (0..stories + 1) |s| for (0..nb) |b| {
        m.nodes[s * nb + b] = .{ .id = @intCast(s * nb + b + 1), .x = @as(f64, @floatFromInt(b)) * bay_w, .y = @as(f64, @floatFromInt(s)) * story_h };
    };
    m.supports = try a.alloc(Support, nb);
    for (0..nb) |b| m.supports[b] = .{ .node = @intCast(b + 1), .ux = true, .uy = true, .rz = true };
    const n_cols = nb * stories;
    const n_beams = bays * stories;
    m.members = try a.alloc(Member, n_cols + n_beams);
    const ids = [_]struct { id: []const u8, w: f64 }{ .{ .id = "D", .w = -20000 }, .{ .id = "L", .w = -10000 }, .{ .id = "W", .w = 0 } };
    var lcs = try a.alloc(LoadCase, 3);
    for (lcs, ids) |*lc, spec| {
        lc.* = .{ .id = spec.id, .nodal = &.{}, .udl = try a.alloc(MemberUdl, if (spec.w != 0) n_beams else 0) };
    }
    var id: usize = 0;
    for (0..nb) |b| for (0..stories) |s| {
        m.members[id] = .{ .id = @intCast(id + 1), .i = @intCast(s * nb + b + 1), .j = @intCast((s + 1) * nb + b + 1), .material = "steel", .section = "COL" };
        id += 1;
    };
    var wl = try a.alloc(NodalLoad, stories);
    var q: usize = 0;
    for (1..stories + 1) |s| {
        for (0..bays) |b| {
            m.members[id] = .{ .id = @intCast(id + 1), .i = @intCast(s * nb + b + 1), .j = @intCast(s * nb + b + 2), .material = "steel", .section = "BM" };
            lcs[0].udl[q] = .{ .member = @intCast(id + 1), .w = -20000 };
            lcs[1].udl[q] = .{ .member = @intCast(id + 1), .w = -10000 };
            q += 1;
            id += 1;
        }
        wl[s - 1] = .{ .node = @intCast(s * nb + 1), .fx = 15000, .fy = 0, .mz = 0 };
    }
    lcs[2].nodal = wl;
    m.load_cases = lcs;
    return m;
}
