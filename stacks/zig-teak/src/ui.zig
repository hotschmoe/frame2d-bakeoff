//! The Teak App: Model / Msg / update from state.zig, the view and the run-loop hooks.
const std = @import("std");
const teak = @import("teak");
const state = @import("state.zig");
const canvas = @import("canvas.zig");
const table = @import("table.zig");
/// Re-exported for the web entry point (web/main.zig imports this file as a module).
pub const state_mod = state;
pub const bench = @import("bench.zig");

pub const Model = state.Model;
pub const Msg = state.Msg;
pub const update = state.update;

// ── hooks ──

pub fn windowMsg(_: *const Model, w: f32, h: f32) ?Msg {
    return .{ .window = .{ w, h } };
}

pub fn pointerMsg(m: *const Model, ev: teak.PointerEvent(Msg)) ?Msg {
    if (ev.asCanvas()) |c| {
        if (c.id == state.CANVAS_ID) return .{ .canvas = c };
        if (table.Table.gripMsg(c, state.GRIP_BASE)) |g| return .{ .table = g };
        return null;
    }
    if (ev.asScroll()) |s| {
        if (s.id == state.TABLE_ID) return .{ .table = .{ .wheel = s.dy } };
        return null;
    }
    if (ev.asSlider()) |s| return .{ .defl_scale = s.value };
    _ = m;
    return null;
}

pub fn scrollLayoutMsg(_: *const Model, id: u32, vw: f32, vh: f32, cw: f32, ch: f32) ?Msg {
    if (id != state.TABLE_ID) return null;
    return .{ .table = .{ .viewport = .{ .vw = vw, .vh = vh, .cw = cw, .ch = ch } } };
}

pub fn modsMsg(_: *const Model, mods: teak.Modifiers) ?Msg {
    return .{ .table = .{ .mods = mods } };
}

pub fn keySpecialMsg(m: *const Model, key: teak.SpecialKey) ?Msg {
    if (key == .escape and m.gen_open) return .gen_close;
    if (table.Table.keyMsg(key, m.tbl.mods)) |k| return .{ .table = k };
    return null;
}

pub fn animationMsg(m: *const Model, dt_ms: u32) ?Msg {
    if (m.bench) |b| if (b.running()) return .{ .bench_tick = dt_ms };
    return .{ .table = .{ .frame = dt_ms } };
}

const anim_subs = [_]teak.Sub(Msg){.animation_frame};

pub fn subscribe(m: *const Model) []const teak.Sub(Msg) {
    if (m.bench) |b| if (b.running()) return &anim_subs;
    return if (m.tbl.animating()) &anim_subs else &.{};
}

pub fn effects(m: *const Model) []const teak.Effect {
    return m.fx[0..m.fx_n];
}

pub fn effectMsg(_: *const Model, r: teak.EffectResult) ?Msg {
    return switch (r) {
        .file_opened => |f| .{ .effect = .{ .id = f.id, .ok = true, .bytes = f.bytes } },
        .file_cancelled => |f| .{ .effect = .{ .id = f.id, .ok = false } },
        .downloaded => |d| .{ .effect = .{ .id = d.id, .ok = d.ok } },
        else => null,
    };
}

pub fn themeFor(_: *const Model) teak.Theme {
    return teak.Theme.dark_default;
}

// ── view ──

fn toolButton(cb: anytype, msg: Msg, label: []const u8) void {
    var s = cb.theme.button;
    s.min_width = 64;
    s.height = 28;
    cb.buttonStyled(msg, label, s);
}

pub fn view(m: *const Model, cb: anytype) void {
    const a = cb.arena.allocator();
    const pal = cb.theme.palette;
    cb.pushGroup(.{ .direction = .vertical, .padding = 8, .gap = 6 });

    // toolbar row 1: file + model
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 6, .align_cross = .center });
    toolButton(cb, .open_file, "Open");
    toolButton(cb, .save_file, "Save");
    toolButton(cb, .gen_open, "Generate");
    toolButton(cb, .solve, "Solve"); // BENCH-EDIT:ui
    toolButton(cb, .fit, "Fit");
    cb.textStyled(m.status(), .{ .size_px = 13, .family = .mono }, pal.fg_muted);
    cb.popGroup();

    // toolbar row 2: overlays + load case
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 12, .align_cross = .center });
    cb.checkbox(.toggle_deflected, m.show_deflected, "Deflected");
    cb.slider(.{ .defl_scale = m.defl_scale }, m.defl_scale);
    cb.checkbox(.toggle_moment, m.show_moment, "Moment");
    cb.checkbox(.toggle_color, m.color_by_m, "Color by |M|");
    cb.textMuted("Case:");
    for (m.m.load_cases, 0..) |lc, k| cb.radio(.{ .case = k }, m.case == k, lc.id);
    cb.popGroup();

    if (m.err) |e| cb.textDanger(e);

    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 8 });
    canvas.view(m, cb);
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 4, .width = state.TABLE_W });
    cb.textMuted(std.fmt.allocPrint(a, "Members ({d})", .{if (m.res) |r| r.member_src.len else 0}) catch "Members");
    table.view(m, cb);
    cb.popGroup();
    cb.popGroup();

    if (m.gen_open) genDialog(m, cb);
    cb.popGroup();
}

fn genDialog(m: *const Model, cb: anytype) void {
    const a = cb.arena.allocator();
    cb.pushOverlay(.{ .x = 0, .y = 0, .width = m.win_w, .height = m.win_h, .modal = true, .backdrop = .{ 0, 0, 0, 0.5 }, .backdrop_msg = .gen_close, .padding = 0 });
    cb.pushGroup(.{ .direction = .vertical, .padding = 16, .gap = 10, .bg = cb.theme.palette.bg_panel, .border = cb.theme.palette.border, .width = 360 });
    cb.heading("Generate frame");
    inline for (.{ .{ "Bays", "gen_bays" }, .{ "Stories", "gen_stories" } }) |row| {
        cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 6, .align_cross = .center });
        cb.text(row[0]);
        const v = if (comptime std.mem.eql(u8, row[1], "gen_bays")) m.gen_b else m.gen_s;
        toolButton(cb, @unionInit(Msg, row[1], -10), "-10");
        toolButton(cb, @unionInit(Msg, row[1], -1), "-1");
        cb.textStyled(std.fmt.allocPrint(a, "{d:>4}", .{v}) catch "?", .{ .size_px = 16, .family = .mono }, cb.theme.text_color);
        toolButton(cb, @unionInit(Msg, row[1], 1), "+1");
        toolButton(cb, @unionInit(Msg, row[1], 10), "+10");
        cb.popGroup();
    }
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 6 });
    toolButton(cb, .{ .gen_preset = .{ 10, 10 } }, "10x10");
    toolButton(cb, .{ .gen_preset = .{ 50, 50 } }, "50x50");
    toolButton(cb, .{ .gen_preset = .{ 100, 100 } }, "100x100");
    toolButton(cb, .{ .gen_preset = .{ 200, 200 } }, "200x200");
    cb.popGroup();
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 6 });
    toolButton(cb, .gen_run, "Generate");
    toolButton(cb, .gen_close, "Cancel");
    cb.popGroup();
    cb.popGroup();
    cb.popOverlay();
}

test "the view builds, balances and stays virtualized for 100x100" {
    var m = Model.init();
    m.generate(100, 100);
    var cb = teak.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();
    view(&m, &cb);
    try std.testing.expect(teak.validateBalance(cb.cmds.items) == null);
    try std.testing.expect(cb.cmds.items.len < 3000);
    try std.testing.expect(m.res != null);
}

test "dragging a node re-solves" {
    var m = Model.init();
    const before = m.res.?.cases[0].disp[60][1];
    update(&m, .{ .canvas = .{ .id = state.CANVAS_ID, .kind = .down, .x = m.toScreen(m.m.nodes[60].x, m.m.nodes[60].y)[0], .y = m.toScreen(m.m.nodes[60].x, m.m.nodes[60].y)[1], .dx = 0, .dy = 0, .button = .left, .buttons = .{ .left = true }, .mods = .{}, .w = 0, .h = 0 } });
    try std.testing.expect(m.drag_node != null);
    update(&m, .{ .canvas = .{ .id = state.CANVAS_ID, .kind = .move, .x = 10, .y = 10, .dx = 0, .dy = 0, .button = .none, .buttons = .{ .left = true }, .mods = .{}, .w = 0, .h = 0 } });
    try std.testing.expect(m.res.?.cases[0].disp[60][1] != before);
}
