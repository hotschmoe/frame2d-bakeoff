//! Model canvas: pan/zoom, drawing (members, deflected shape, moment diagram, supports) and node dragging.
//! Everything is drawn as batched triangles (one quad per line segment) through dvui.renderTriangles.
const std = @import("std");
const dvui = @import("dvui");
const engine = @import("engine");
const solver = engine.solver;
const state = @import("state.zig");
const App = state.App;

const Vertex = dvui.Vertex;
const Index = Vertex.Index;
const Pma = dvui.Color.PMA;

const max_quads = 16000;
var vbuf: [max_quads * 4]Vertex = undefined;
var ibuf: [max_quads * 6]Index = undefined;

const Pt = struct { x: f32, y: f32 };

/// Batches colored quads and flushes them to dvui in as few draw calls as possible.
const Painter = struct {
    nv: usize = 0,
    ni: usize = 0,
    bounds: dvui.Rect.Physical,
    quads: usize = 0,

    fn flush(self: *Painter) void {
        if (self.ni == 0) return;
        const tri: dvui.Triangles = .{
            .vertexes = vbuf[0..self.nv],
            .indices = ibuf[0..self.ni],
            .bounds = self.bounds,
        };
        dvui.renderTriangles(tri, null) catch {};
        self.nv = 0;
        self.ni = 0;
    }

    fn quad(self: *Painter, p0: Pt, p1: Pt, p2: Pt, p3: Pt, col: Pma) void {
        if (self.nv + 4 > vbuf.len) self.flush();
        const b: Index = @intCast(self.nv);
        const ps = [4]Pt{ p0, p1, p2, p3 };
        for (ps, 0..) |p, k| vbuf[self.nv + k] = .{ .pos = .{ .x = p.x, .y = p.y }, .col = col };
        self.nv += 4;
        // the winding must be counter-clockwise on screen (y down); flip if it is not
        const cross = (p1.x - p0.x) * (p2.y - p0.y) - (p1.y - p0.y) * (p2.x - p0.x);
        const tris = if (cross < 0) [6]Index{ b, b + 1, b + 2, b, b + 2, b + 3 } else [6]Index{ b, b + 2, b + 1, b, b + 3, b + 2 };
        @memcpy(ibuf[self.ni .. self.ni + 6], &tris);
        self.ni += 6;
        self.quads += 1;
    }

    fn line(self: *Painter, a: Pt, b: Pt, w: f32, col: Pma) void {
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const len = @sqrt(dx * dx + dy * dy);
        const hw = w * 0.5;
        const nx = if (len > 1e-6) -dy / len * hw else 0;
        const ny = if (len > 1e-6) dx / len * hw else hw;
        self.quad(
            .{ .x = a.x + nx, .y = a.y + ny },
            .{ .x = a.x - nx, .y = a.y - ny },
            .{ .x = b.x - nx, .y = b.y - ny },
            .{ .x = b.x + nx, .y = b.y + ny },
            col,
        );
    }

    fn square(self: *Painter, c: Pt, half: f32, col: Pma) void {
        self.quad(
            .{ .x = c.x - half, .y = c.y - half },
            .{ .x = c.x + half, .y = c.y - half },
            .{ .x = c.x + half, .y = c.y + half },
            .{ .x = c.x - half, .y = c.y + half },
            col,
        );
    }
};

fn rgb(r: u8, g: u8, b: u8) Pma {
    return Pma.fromColor(.{ .r = r, .g = g, .b = b, .a = 255 });
}

fn rgba(r: u8, g: u8, b: u8, a: u8) Pma {
    return Pma.fromColor(.{ .r = r, .g = g, .b = b, .a = a });
}

fn lerpU8(a: u8, b: u8, t: f32) u8 {
    return @intFromFloat(@as(f32, @floatFromInt(a)) * (1 - t) + @as(f32, @floatFromInt(b)) * t);
}

/// blue -> yellow -> red
fn heat(t_in: f32) Pma {
    const t = std.math.clamp(t_in, 0, 1);
    if (t < 0.5) {
        const u = t * 2;
        return rgb(lerpU8(60, 235, u), lerpU8(120, 200, u), lerpU8(230, 50, u));
    }
    const u = (t - 0.5) * 2;
    return rgb(lerpU8(235, 225, u), lerpU8(200, 50, u), lerpU8(50, 50, u));
}

pub const Geometry = struct {
    /// canvas rectangle (physical px)
    r: dvui.Rect.Physical,
    /// physical pixels per logical pixel
    ps: f32,

    fn toScreen(g: Geometry, v: state.View, x: f64, y: f64) Pt {
        return .{
            .x = @floatCast(g.r.x + g.r.w * 0.5 + (x - v.cx) * v.scale),
            .y = @floatCast(g.r.y + g.r.h * 0.5 - (y - v.cy) * v.scale),
        };
    }

    fn toWorld(g: Geometry, v: state.View, p: dvui.Point.Physical) struct { x: f64, y: f64 } {
        return .{
            .x = v.cx + (p.x - (g.r.x + g.r.w * 0.5)) / v.scale,
            .y = v.cy - (p.y - (g.r.y + g.r.h * 0.5)) / v.scale,
        };
    }
};

pub fn fitView(app: *App, g: Geometry) void {
    const nodes = app.model.nodes;
    if (nodes.len == 0 or g.r.w < 1 or g.r.h < 1) return;
    var minx = nodes[0].x;
    var maxx = nodes[0].x;
    var miny = nodes[0].y;
    var maxy = nodes[0].y;
    for (nodes) |n| {
        minx = @min(minx, n.x);
        maxx = @max(maxx, n.x);
        miny = @min(miny, n.y);
        maxy = @max(maxy, n.y);
    }
    const w = @max(maxx - minx, 1.0);
    const h = @max(maxy - miny, 1.0);
    app.view = .{
        .cx = (minx + maxx) / 2,
        .cy = (miny + maxy) / 2,
        .scale = @min(g.r.w / w, g.r.h / h) * 0.85,
    };
    app.fit_pending = false;
}

fn modelSize(app: *const App) f64 {
    const nodes = app.model.nodes;
    if (nodes.len == 0) return 1;
    var minx = nodes[0].x;
    var maxx = nodes[0].x;
    var miny = nodes[0].y;
    var maxy = nodes[0].y;
    for (nodes) |n| {
        minx = @min(minx, n.x);
        maxx = @max(maxx, n.x);
        miny = @min(miny, n.y);
        maxy = @max(maxy, n.y);
    }
    return @max(@max(maxx - minx, maxy - miny), 1.0);
}

pub fn deflectionMagnification(app: *const App) f64 {
    if (app.max_disp <= 0) return 0;
    const auto = 0.03 * modelSize(app) / app.max_disp;
    return auto * std.math.pow(f64, 10, 2.0 * app.defl_slider - 1.0);
}

fn momentScale(app: *const App) f64 {
    if (app.max_m_model <= 0) return 0;
    const auto = 0.08 * modelSize(app) / app.max_m_model;
    return auto * std.math.pow(f64, 10, 2.0 * app.moment_slider - 1.0);
}

// ---------------------------------------------------------------------------------------------- drawing

fn visible(g: Geometry, a: Pt, b: Pt) bool {
    const margin: f32 = 4;
    const left = g.r.x - margin;
    const right = g.r.x + g.r.w + margin;
    const top = g.r.y - margin;
    const bot = g.r.y + g.r.h + margin;
    if (a.x < left and b.x < left) return false;
    if (a.x > right and b.x > right) return false;
    if (a.y < top and b.y < top) return false;
    if (a.y > bot and b.y > bot) return false;
    return true;
}

pub fn draw(app: *App, g: Geometry) void {
    var p = Painter{ .bounds = g.r };
    const prev_clip = dvui.clip(g.r);
    defer dvui.clipSet(prev_clip);

    const v = app.view;
    const nodes = app.model.nodes;
    const members = app.model.members;
    const ps = g.ps;
    const res_ok = app.caseResult();

    // undeformed members, colored by max |M|
    const base_w: f32 = 1.5 * ps;
    const gray = rgb(150, 156, 172);
    const faint = rgba(150, 156, 172, 90);
    // member endpoints are looked up by index (nodes and members are sorted by id, i/j resolved once per frame)
    const ends = memberEnds(app);
    for (0..members.len) |k| {
        const ia = ends[k * 2];
        const ib = ends[k * 2 + 1];
        const a = g.toScreen(v, nodes[ia].x, nodes[ia].y);
        const b = g.toScreen(v, nodes[ib].x, nodes[ib].y);
        if (!visible(g, a, b)) continue;
        var col = if (app.show_deflected and res_ok != null) faint else gray;
        if (app.color_by_moment and res_ok != null and app.max_m_model > 0 and k < app.member_max_m.len) {
            col = heat(@floatCast(app.member_max_m[k] / app.max_m_model));
        }
        p.line(a, b, base_w, col);
    }
    p.flush();

    // deflected shape
    if (app.show_deflected) {
        if (res_ok) |cr| {
            const mag = deflectionMagnification(app);
            const col = rgb(255, 150, 40);
            for (0..members.len) |k| {
                const ia = ends[k * 2];
                const ib = ends[k * 2 + 1];
                const a = g.toScreen(v, nodes[ia].x, nodes[ia].y);
                const b = g.toScreen(v, nodes[ib].x, nodes[ib].y);
                if (!visible(g, a, b)) continue;
                drawDeflected(&p, g, v, app, cr, k, ia, ib, mag, col, 2.0 * ps);
            }
            p.flush();
        }
    }

    // moment diagram
    if (app.show_moment) {
        if (res_ok) |cr| {
            const ks = momentScale(app);
            const col = rgb(120, 220, 160);
            for (0..members.len) |k| {
                const ia = ends[k * 2];
                const ib = ends[k * 2 + 1];
                const a = g.toScreen(v, nodes[ia].x, nodes[ia].y);
                const b = g.toScreen(v, nodes[ib].x, nodes[ib].y);
                if (!visible(g, a, b)) continue;
                drawMoment(&p, g, v, app, cr, k, ia, ib, ks, col, 1.5 * ps);
            }
            p.flush();
        }
    }

    // supports
    for (app.model.supports) |sp| {
        const idx = solver.findNode(nodes, sp.node) orelse continue;
        const c = g.toScreen(v, nodes[idx].x, nodes[idx].y);
        if (c.x < g.r.x - 10 or c.x > g.r.x + g.r.w + 10 or c.y < g.r.y - 10 or c.y > g.r.y + g.r.h + 10) continue;
        const all = sp.ux and sp.uy and sp.rz;
        p.square(c, 4.5 * ps, if (all) rgb(220, 70, 70) else rgb(80, 150, 240));
    }

    // node markers when zoomed in enough
    const spacing_px = if (members.len > 0) nominalMemberPx(app, g, ends) else 0;
    if (spacing_px > 14 * ps) {
        for (nodes) |n| {
            const c = g.toScreen(v, n.x, n.y);
            if (c.x < g.r.x or c.x > g.r.x + g.r.w or c.y < g.r.y or c.y > g.r.y + g.r.h) continue;
            p.square(c, 2.0 * ps, rgb(225, 228, 238));
        }
    }
    if (app.hover_node) |h| {
        if (h < nodes.len) p.square(g.toScreen(v, nodes[h].x, nodes[h].y), 5 * ps, rgb(255, 235, 120));
    }
    if (app.selected_node) |h| {
        if (h < nodes.len) p.square(g.toScreen(v, nodes[h].x, nodes[h].y), 6 * ps, rgb(255, 120, 200));
    }

    // nodal loads of the shown case
    if (app.case < app.model.load_cases.len) {
        for (app.model.load_cases[app.case].nodal) |ld| {
            const idx = solver.findNode(nodes, ld.node) orelse continue;
            const c = g.toScreen(v, nodes[idx].x, nodes[idx].y);
            drawArrow(&p, c, @floatCast(ld.fx), @floatCast(-ld.fy), ps);
        }
    }
    p.flush();
}

fn drawArrow(p: *Painter, tip: Pt, fx: f32, fy_down: f32, ps: f32) void {
    const mag = @sqrt(fx * fx + fy_down * fy_down);
    if (mag == 0) return;
    const len = 34 * ps;
    const ux = fx / mag;
    const uy = fy_down / mag;
    const tail = Pt{ .x = tip.x - ux * len, .y = tip.y - uy * len };
    const col = rgb(250, 90, 90);
    p.line(tail, tip, 2 * ps, col);
    const hx = 8 * ps;
    p.line(tip, .{ .x = tip.x - ux * hx - uy * hx * 0.5, .y = tip.y - uy * hx + ux * hx * 0.5 }, 2 * ps, col);
    p.line(tip, .{ .x = tip.x - ux * hx + uy * hx * 0.5, .y = tip.y - uy * hx - ux * hx * 0.5 }, 2 * ps, col);
}

var ends_buf: []u32 = &.{};
var ends_epoch: u32 = std.math.maxInt(u32);

/// Node indices of every member's i and j end, cached across frames (topology only changes on model load).
fn memberEnds(app: *App) []const u32 {
    if (ends_epoch != app.epoch or ends_buf.len != app.model.members.len * 2) {
        app.gpa.free(ends_buf);
        ends_buf = app.gpa.alloc(u32, app.model.members.len * 2) catch &.{};
        for (app.model.members, 0..) |m, k| {
            if (k * 2 + 1 >= ends_buf.len) break;
            ends_buf[k * 2] = solver.findNode(app.model.nodes, m.i) orelse 0;
            ends_buf[k * 2 + 1] = solver.findNode(app.model.nodes, m.j) orelse 0;
        }
        ends_epoch = app.epoch;
    }
    return ends_buf;
}

fn nominalMemberPx(app: *const App, g: Geometry, ends: []const u32) f32 {
    _ = g;
    // use the first member as a proxy for the typical member size
    const n = app.model.nodes;
    const a = n[ends[0]];
    const b = n[ends[1]];
    const dx = (b.x - a.x) * app.view.scale;
    const dy = (b.y - a.y) * app.view.scale;
    return @floatCast(@sqrt(dx * dx + dy * dy));
}

fn drawDeflected(p: *Painter, g: Geometry, v: state.View, app: *const App, cr: *const solver.CaseResult, k: usize, ia: u32, ib: u32, mag: f64, col: Pma, w: f32) void {
    const nodes = app.model.nodes;
    const res = &app.results.?;
    const l = res.length[k];
    const xa = nodes[ia].x;
    const ya = nodes[ia].y;
    const c = (nodes[ib].x - xa) / l;
    const s = (nodes[ib].y - ya) / l;
    // end displacements in the member's local axes
    const ua = [3]f64{ cr.u[ia * 3], cr.u[ia * 3 + 1], cr.u[ia * 3 + 2] };
    const ub = [3]f64{ cr.u[ib * 3], cr.u[ib * 3 + 1], cr.u[ib * 3 + 2] };
    const ax1 = c * ua[0] + s * ua[1];
    const v1 = -s * ua[0] + c * ua[1];
    const ax2 = c * ub[0] + s * ub[1];
    const v2 = -s * ub[0] + c * ub[1];
    const t1 = ua[2];
    const t2 = ub[2];

    const sa = g.toScreen(v, xa, ya);
    const sb = g.toScreen(v, nodes[ib].x, nodes[ib].y);
    const len_px = @sqrt((sb.x - sa.x) * (sb.x - sa.x) + (sb.y - sa.y) * (sb.y - sa.y));
    const nseg: usize = std.math.clamp(@as(usize, @intFromFloat(len_px / (8 * g.ps))) + 1, 1, 12);

    var prev: Pt = undefined;
    for (0..nseg + 1) |q| {
        const xi = @as(f64, @floatFromInt(q)) / @as(f64, @floatFromInt(nseg));
        const n1 = 1 - 3 * xi * xi + 2 * xi * xi * xi;
        const n2 = xi - 2 * xi * xi + xi * xi * xi;
        const n3 = 3 * xi * xi - 2 * xi * xi * xi;
        const n4 = -xi * xi + xi * xi * xi;
        const dl = ax1 + (ax2 - ax1) * xi;
        const dt = v1 * n1 + t1 * l * n2 + v2 * n3 + t2 * l * n4;
        const dx = c * dl - s * dt;
        const dy = s * dl + c * dt;
        const pt = g.toScreen(v, xa + c * l * xi + mag * dx, ya + s * l * xi + mag * dy);
        if (q > 0) p.line(prev, pt, w, col);
        prev = pt;
    }
}

fn drawMoment(p: *Painter, g: Geometry, v: state.View, app: *const App, cr: *const solver.CaseResult, k: usize, ia: u32, ib: u32, ks: f64, col: Pma, w: f32) void {
    const nodes = app.model.nodes;
    const res = &app.results.?;
    const l = res.length[k];
    const xa = nodes[ia].x;
    const ya = nodes[ia].y;
    const c = (nodes[ib].x - xa) / l;
    const s = (nodes[ib].y - ya) / l;
    const sa = g.toScreen(v, xa, ya);
    const sb = g.toScreen(v, nodes[ib].x, nodes[ib].y);
    const len_px = @sqrt((sb.x - sa.x) * (sb.x - sa.x) + (sb.y - sa.y) * (sb.y - sa.y));
    // number of segments: 1, 2, 5 or 10 of the 10 station intervals
    const stride: usize = if (len_px < 12 * g.ps) 10 else if (len_px < 30 * g.ps) 5 else if (len_px < 60 * g.ps) 2 else 1;
    const ef = cr.end_forces[k * 6 ..][0..6];
    var prev: Pt = undefined;
    var q: usize = 0;
    while (q <= 10) : (q += stride) {
        const st = solver.station(ef, cr.w[k], l, q);
        // plotted on the tension side: sagging (positive) moment goes to -local y
        const off = -st.M * ks;
        const pt = g.toScreen(v, xa + c * st.x - s * off, ya + s * st.x + c * off);
        if (q == 0) {
            p.line(sa, pt, w * 0.6, col);
        } else {
            p.line(prev, pt, w, col);
        }
        prev = pt;
    }
    p.line(sb, prev, w * 0.6, col);
}

// ---------------------------------------------------------------------------------------------- input

const Interaction = struct {
    mode: enum { none, pan, node } = .none,
    pinch_base: f64 = 1,
};
var inter: Interaction = .{};

fn zoomAbout(app: *App, g: Geometry, p: dvui.Point.Physical, factor: f64) void {
    const w = g.toWorld(app.view, p);
    const ns = std.math.clamp(app.view.scale * factor, 0.01, 1.0e6);
    app.view.scale = ns;
    app.view.cx = w.x - (p.x - (g.r.x + g.r.w * 0.5)) / ns;
    app.view.cy = w.y + (p.y - (g.r.y + g.r.h * 0.5)) / ns;
}

fn nearestNode(app: *const App, g: Geometry, p: dvui.Point.Physical, max_px: f32) ?usize {
    const w = g.toWorld(app.view, p);
    const lim = @as(f64, max_px) / app.view.scale;
    var best: ?usize = null;
    var best_d: f64 = lim * lim;
    for (app.model.nodes, 0..) |n, k| {
        const dx = n.x - w.x;
        const dy = n.y - w.y;
        const d = dx * dx + dy * dy;
        if (d < best_d) {
            best_d = d;
            best = k;
        }
    }
    return best;
}

/// Mouse/touch handling. Returns true when a node moved and the model needs a new solve.
pub fn handleEvents(app: *App, wd: *dvui.WidgetData, g: Geometry) void {
    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, wd)) continue;
        switch (e.evt) {
            .mouse => |me| switch (me.action) {
                .press => {
                    if (me.button.pointer() or me.button == .middle or me.button == .right) {
                        e.handle(@src(), wd);
                        app.fit_pending = false;
                        dvui.captureMouse(wd, e.num);
                        const hit = if (me.button.pointer()) nearestNode(app, g, me.p, 12 * g.ps) else null;
                        if (hit) |h| {
                            app.selected_node = h;
                            app.dragging_node = true;
                            inter.mode = .node;
                        } else {
                            inter.mode = .pan;
                        }
                    }
                },
                .release => {
                    if (dvui.captured(wd.id)) {
                        e.handle(@src(), wd);
                        dvui.captureMouse(null, e.num);
                        inter.mode = .none;
                        app.dragging_node = false;
                    }
                },
                .motion => |d| {
                    if (dvui.captured(wd.id)) {
                        e.handle(@src(), wd);
                        switch (inter.mode) {
                            .pan => {
                                app.view.cx -= d.x / app.view.scale;
                                app.view.cy += d.y / app.view.scale;
                            },
                            .node => {
                                if (app.selected_node) |sn| {
                                    const w = g.toWorld(app.view, me.p);
                                    app.model.nodes[sn].x = w.x;
                                    app.model.nodes[sn].y = w.y;
                                    app.dirty = true;
                                }
                            },
                            .none => {},
                        }
                    }
                },
                .wheel_y => |dy| {
                    app.fit_pending = false;
                    e.handle(@src(), wd);
                    zoomAbout(app, g, me.p, std.math.pow(f64, 1.15, dy));
                },
                .pinch_begin => {
                    inter.pinch_base = app.view.scale;
                },
                .pinch_update => |z| {
                    app.fit_pending = false;
                    e.handle(@src(), wd);
                    const target = inter.pinch_base * z;
                    zoomAbout(app, g, me.p, target / app.view.scale);
                },
                .position => {
                    if (!app.dragging_node) app.hover_node = nearestNode(app, g, me.p, 10 * g.ps);
                },
                else => {},
            },
            else => {},
        }
    }
}
