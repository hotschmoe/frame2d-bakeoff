//! Deterministic B-bay x S-story moment frame generator (SPEC 4.8).
const std = @import("std");
const model = @import("model.zig");

pub const bay_width = 6.0;
pub const story_height = 3.5;

pub fn generate(gpa: std.mem.Allocator, bays: u32, stories: u32) error{OutOfMemory}!model.Model {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const cols = bays + 1;
    const n_nodes = cols * (stories + 1);
    const n_cols = cols * stories;
    const n_beams = bays * stories;

    const materials = try a.alloc(model.Material, 1);
    materials[0] = .{ .id = "steel", .E = 200e9 };
    const sections = try a.alloc(model.Section, 2);
    sections[0] = .{ .id = "COL", .A = 0.015, .I = 1.2e-4 };
    sections[1] = .{ .id = "BM", .A = 0.010, .I = 8.0e-5 };

    const nodes = try a.alloc(model.Node, n_nodes);
    const restraint = try a.alloc(u8, n_nodes);
    for (0..stories + 1) |s| {
        for (0..cols) |b| {
            const k = s * cols + b;
            nodes[k] = .{ .id = @intCast(k + 1), .x = @as(f64, @floatFromInt(b)) * bay_width, .y = @as(f64, @floatFromInt(s)) * story_height };
            restraint[k] = if (s == 0) model.UX | model.UY | model.RZ else 0;
        }
    }

    const members = try a.alloc(model.Member, n_cols + n_beams);
    var mi: usize = 0;
    for (0..cols) |b| {
        for (0..stories) |s| {
            members[mi] = .{ .id = @intCast(mi + 1), .i = @intCast(s * cols + b), .j = @intCast((s + 1) * cols + b), .mat = 0, .sec = 0 };
            mi += 1;
        }
    }
    const first_beam = mi;
    for (1..stories + 1) |s| {
        for (0..bays) |b| {
            members[mi] = .{ .id = @intCast(mi + 1), .i = @intCast(s * cols + b), .j = @intCast(s * cols + b + 1), .mat = 0, .sec = 1 };
            mi += 1;
        }
    }

    const cases = try a.alloc(model.LoadCase, 3);
    const loads = [_]struct { id: []const u8, w: f64 }{ .{ .id = "D", .w = -20000 }, .{ .id = "L", .w = -10000 } };
    for (loads, 0..) |l, c| {
        const udl = try a.alloc(model.UdlLoad, n_beams);
        for (udl, 0..) |*u, k| u.* = .{ .member = @intCast(first_beam + k), .w = l.w };
        cases[c] = .{ .id = l.id, .nodal = &.{}, .udl = udl };
    }
    const wind = try a.alloc(model.NodalLoad, stories);
    for (wind, 0..) |*l, k| l.* = .{ .node = @intCast((k + 1) * cols), .fx = 15000, .fy = 0, .mz = 0 };
    cases[2] = .{ .id = "W", .nodal = wind, .udl = &.{} };

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
