//! Allocator wrapper that counts allocations (SPEC 5.2 alloc_count / alloc_bytes / peak_heap_bytes).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const Counting = @This();

backing: Allocator,
count: std.atomic.Value(u64) = .init(0),
bytes: std.atomic.Value(u64) = .init(0),
live: std.atomic.Value(u64) = .init(0),
peak: std.atomic.Value(u64) = .init(0),

pub fn init(backing: Allocator) Counting {
    return .{ .backing = backing };
}

pub fn reset(c: *Counting) void {
    c.count.store(0, .monotonic);
    c.bytes.store(0, .monotonic);
    c.live.store(0, .monotonic);
    c.peak.store(0, .monotonic);
}

pub fn allocator(c: *Counting) Allocator {
    return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
}

fn grow(c: *Counting, n: usize) void {
    _ = c.count.fetchAdd(1, .monotonic);
    _ = c.bytes.fetchAdd(n, .monotonic);
    const live = c.live.fetchAdd(n, .monotonic) + n;
    _ = c.peak.fetchMax(live, .monotonic);
}

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const c: *Counting = @ptrCast(@alignCast(ctx));
    const p = c.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
    c.grow(len);
    return p;
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const c: *Counting = @ptrCast(@alignCast(ctx));
    if (!c.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
    c.adjust(memory.len, new_len);
    return true;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const c: *Counting = @ptrCast(@alignCast(ctx));
    const p = c.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
    c.adjust(memory.len, new_len);
    return p;
}

fn adjust(c: *Counting, old: usize, new: usize) void {
    if (new > old) {
        _ = c.bytes.fetchAdd(new - old, .monotonic);
        const live = c.live.fetchAdd(new - old, .monotonic) + (new - old);
        _ = c.peak.fetchMax(live, .monotonic);
    } else {
        _ = c.live.fetchSub(old - new, .monotonic);
    }
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const c: *Counting = @ptrCast(@alignCast(ctx));
    _ = c.live.fetchSub(memory.len, .monotonic);
    c.backing.rawFree(memory, alignment, ret_addr);
}
