//! Small helpers: growable list, byte buffer with number formatting, counting allocator, clock.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Growable list that never frees on its own (meant for arena allocators).
pub fn List(comptime T: type) type {
    return struct {
        const Self = @This();
        buf: []T = &.{},
        len: usize = 0,

        pub fn append(self: *Self, a: Allocator, v: T) Allocator.Error!void {
            if (self.len == self.buf.len) try self.grow(a, self.len + 1);
            self.buf[self.len] = v;
            self.len += 1;
        }

        pub fn appendSlice(self: *Self, a: Allocator, vs: []const T) Allocator.Error!void {
            if (self.len + vs.len > self.buf.len) try self.grow(a, self.len + vs.len);
            @memcpy(self.buf[self.len..][0..vs.len], vs);
            self.len += vs.len;
        }

        fn grow(self: *Self, a: Allocator, need: usize) Allocator.Error!void {
            var cap = if (self.buf.len == 0) 8 else self.buf.len * 2;
            while (cap < need) cap *= 2;
            self.buf = if (self.buf.len == 0) try a.alloc(T, cap) else try a.realloc(self.buf, cap);
        }

        pub fn items(self: *const Self) []T {
            return self.buf[0..self.len];
        }
    };
}

/// Byte buffer used to build JSON text.
pub const Buf = struct {
    list: List(u8) = .{},
    a: Allocator,

    pub fn raw(self: *Buf, s: []const u8) Allocator.Error!void {
        try self.list.appendSlice(self.a, s);
    }

    pub fn byte(self: *Buf, c: u8) Allocator.Error!void {
        try self.list.append(self.a, c);
    }

    pub fn int(self: *Buf, v: anytype) Allocator.Error!void {
        var tmp: [32]u8 = undefined;
        try self.raw(std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable);
    }

    /// Shortest round-trip float, JSON-valid. Non-finite values become null.
    pub fn num(self: *Buf, v: f64) Allocator.Error!void {
        if (!std.math.isFinite(v)) return self.raw("null");
        var tmp: [64]u8 = undefined;
        try self.raw(std.fmt.bufPrint(&tmp, "{e}", .{v}) catch unreachable);
    }

    pub fn str(self: *Buf, s: []const u8) Allocator.Error!void {
        try self.byte('"');
        for (s) |c| switch (c) {
            '"' => try self.raw("\\\""),
            '\\' => try self.raw("\\\\"),
            '\n' => try self.raw("\\n"),
            '\r' => try self.raw("\\r"),
            '\t' => try self.raw("\\t"),
            0...8, 11, 12, 14...31 => {
                var tmp: [6]u8 = undefined;
                try self.raw(std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable);
            },
            else => try self.byte(c),
        };
        try self.byte('"');
    }

    pub fn slice(self: *Buf) []u8 {
        return self.list.items();
    }

    /// Trim capacity so the result can be freed with its own length.
    pub fn finish(self: *Buf) Allocator.Error![]u8 {
        if (self.list.len == 0) return &.{};
        return self.a.realloc(self.list.buf, self.list.len);
    }
};

/// Allocator wrapper that counts allocations, bytes requested and the peak of live bytes
/// (SPEC 5.2: "counting wrapper around the allocator passed to the engine").
pub const Counting = struct {
    child: Allocator,
    count: u64 = 0,
    bytes: u64 = 0,
    live: u64 = 0,
    peak: u64 = 0,

    pub fn init(child: Allocator) Counting {
        return .{ .child = child };
    }

    pub fn allocator(self: *Counting) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn note(self: *Counting, old: usize, new: usize) void {
        self.live = self.live - old + new;
        if (new > old) self.bytes += new - old;
        if (self.live > self.peak) self.peak = self.live;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ra) orelse return null;
        self.count += 1;
        self.note(0, len);
        return p;
    }

    fn resize(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(mem, alignment, new_len, ra)) return false;
        self.note(mem.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(mem, alignment, new_len, ra) orelse return null;
        self.note(mem.len, new_len);
        return p;
    }

    fn free(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(mem, alignment, ra);
        self.live -= mem.len;
    }
};

// ---- clock ----

extern "env" fn f2d_now_ms() f64;
extern "kernel32" fn QueryPerformanceCounter(c: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(f: *i64) callconv(.winapi) i32;

/// Monotonic time in milliseconds.
pub fn nowMs() f64 {
    if (builtin.cpu.arch.isWasm()) return f2d_now_ms();
    if (builtin.os.tag == .windows) {
        var c: i64 = 0;
        var f: i64 = 1;
        _ = QueryPerformanceCounter(&c);
        _ = QueryPerformanceFrequency(&f);
        return @as(f64, @floatFromInt(c)) * 1000.0 / @as(f64, @floatFromInt(f));
    }
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.sec)) * 1000.0 + @as(f64, @floatFromInt(ts.nsec)) / 1.0e6;
}

/// Process-wide allocator for the C ABI (thread-safe, no libc needed).
pub const backing: Allocator = if (builtin.cpu.arch.isWasm()) std.heap.wasm_allocator else std.heap.smp_allocator;
