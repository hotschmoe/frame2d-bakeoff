//! Allocator wrapper that counts calls and bytes (SPEC 5.2 alloc_count / alloc_bytes / peak_heap_bytes).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const Self = @This();

child: Allocator,
count: u64 = 0,
bytes: u64 = 0,
live: u64 = 0,
peak: u64 = 0,

pub fn init(child: Allocator) Self {
    return .{ .child = child };
}

pub fn reset(self: *Self) void {
    self.count = 0;
    self.bytes = 0;
    self.live = 0;
    self.peak = 0;
}

pub fn allocator(self: *Self) Allocator {
    return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
}

fn grow(self: *Self, n: usize) void {
    self.count += 1;
    self.bytes += n;
    self.live += n;
    self.peak = @max(self.peak, self.live);
}

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const p = self.child.rawAlloc(len, alignment, ra) orelse return null;
    self.grow(len);
    return p;
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (!self.child.rawResize(memory, alignment, new_len, ra)) return false;
    self.live = self.live - memory.len + new_len;
    self.peak = @max(self.peak, self.live);
    return true;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const p = self.child.rawRemap(memory, alignment, new_len, ra) orelse return null;
    self.live = self.live - memory.len + new_len;
    self.peak = @max(self.peak, self.live);
    return p;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.child.rawFree(memory, alignment, ra);
    self.live -= memory.len;
}
