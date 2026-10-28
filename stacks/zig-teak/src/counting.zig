//! Counting allocator wrapper for the CLI's alloc stats (SPEC 5.2). Single-threaded use.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Counting = struct {
    child: Allocator,
    count: u64 = 0,
    bytes: u64 = 0,
    live: u64 = 0,
    peak: u64 = 0,

    pub fn allocator(self: *Counting) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    pub fn reset(self: *Counting) void {
        self.count = 0;
        self.bytes = 0;
        self.peak = self.live;
    }

    fn grow(self: *Counting, old: usize, new: usize) void {
        if (new > old) self.bytes += new - old;
        self.live = self.live + new - old;
        self.peak = @max(self.peak, self.live);
    }

    fn alloc(ctx: *anyopaque, len: usize, al: Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, al, ra) orelse return null;
        self.count += 1;
        self.grow(0, len);
        return p;
    }
    fn resize(ctx: *anyopaque, mem: []u8, al: Alignment, new_len: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(mem, al, new_len, ra)) return false;
        self.grow(mem.len, new_len);
        return true;
    }
    fn remap(ctx: *anyopaque, mem: []u8, al: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(mem, al, new_len, ra) orelse return null;
        self.grow(mem.len, new_len);
        return p;
    }
    fn free(ctx: *anyopaque, mem: []u8, al: Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(mem, al, ra);
        self.live -= mem.len;
    }
};
