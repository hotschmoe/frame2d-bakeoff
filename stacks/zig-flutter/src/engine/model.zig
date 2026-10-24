//! Frame2D model types (SPEC 4.1, 5.1). Nodes and members are kept sorted by id; all cross references
//! are resolved to indices when the model is built, so the solver never searches by id.
const std = @import("std");

pub const ErrCode = enum {
    invalid_json,
    invalid_ref,
    zero_length,
    duplicate_id,
    unstable,
    no_free_dofs,
};

/// A model-level error with a human readable detail, reported as {"error": code, "detail": ...}.
pub const Diag = struct {
    code: ErrCode = .invalid_json,
    buf: [160]u8 = undefined,
    len: usize = 0,

    pub fn set(d: *Diag, code: ErrCode, comptime fmt: []const u8, args: anytype) error{Model} {
        d.code = code;
        const s = std.fmt.bufPrint(&d.buf, fmt, args) catch d.buf[0..0];
        d.len = s.len;
        return error.Model;
    }

    pub fn detail(d: *const Diag) []const u8 {
        return d.buf[0..d.len];
    }
};

pub const Node = struct {
    id: i32,
    x: f64,
    y: f64,
    bench_pad: u32 = 0, // BENCH-EDIT:struct
};

pub const Material = struct { id: []const u8, E: f64 };
pub const Section = struct { id: []const u8, A: f64, I: f64 };

pub const Member = struct {
    id: i32,
    /// Node indices (not ids).
    i: u32,
    j: u32,
    mat: u32,
    sec: u32,
};

/// Restraint bits for `Model.restraint`.
pub const UX: u8 = 1;
pub const UY: u8 = 2;
pub const RZ: u8 = 4;

pub const NodalLoad = struct { node: u32, fx: f64, fy: f64, mz: f64 };
pub const UdlLoad = struct { member: u32, w: f64 };

pub const LoadCase = struct {
    id: []const u8,
    nodal: []NodalLoad,
    udl: []UdlLoad,
};

pub const Model = struct {
    /// Owns every slice below.
    arena: std.heap.ArenaAllocator,
    materials: []Material,
    sections: []Section,
    nodes: []Node,
    members: []Member,
    /// One bitmask per node (UX|UY|RZ), indexed like `nodes`.
    restraint: []u8,
    load_cases: []LoadCase,

    pub fn deinit(m: *Model) void {
        m.arena.deinit();
    }

    /// Index of the node with this id (nodes are sorted by id), or null.
    pub fn nodeIndex(m: *const Model, id: i32) ?u32 {
        return indexById(Node, m.nodes, id);
    }

    pub fn memberIndex(m: *const Model, id: i32) ?u32 {
        return indexById(Member, m.members, id);
    }

    pub fn memberLength(m: *const Model, k: usize) f64 {
        const mem = m.members[k];
        const a = m.nodes[mem.i];
        const b = m.nodes[mem.j];
        return std.math.hypot(b.x - a.x, b.y - a.y);
    }
};

fn indexById(comptime T: type, items: []const T, id: i32) ?u32 {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid].id < id) lo = mid + 1 else hi = mid;
    }
    if (lo < items.len and items[lo].id == id) return @intCast(lo);
    return null;
}
