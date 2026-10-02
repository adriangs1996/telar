//! Experiment only: decides where large allocations land, to test whether
//! object placement alone changes a hot path. `color` shifts each large
//! record by a different offset inside its first page; `pack` carves every
//! large record from one contiguous region without page alignment.
const std = @import("std");
const PlacementAllocator = @This();

pub const Mode = enum { none, color, pack, shift };

const page = 16 * 1024;
const color_stride = 512;
const colors = page / color_stride;
const region_bytes = 1024 * 1024 * 1024;
const max_tracked = 2048;
const max_classes = 32;

child: std.mem.Allocator,
mode: Mode,
threshold: usize = 32 * 1024,
lock: std.atomic.Value(bool) = .init(false),
tracked_ptr: [max_tracked]usize = @splat(0),
tracked_base: [max_tracked]usize = @splat(0),
tracked_len: [max_tracked]usize = @splat(0),
class_len: [max_classes]usize = @splat(0),
class_next: [max_classes]usize = @splat(0),
region: []u8 = &.{},
region_used: usize = 0,
placed: usize = 0,

pub fn init(child: std.mem.Allocator, mode: Mode) !PlacementAllocator {
    var self: PlacementAllocator = .{ .child = child, .mode = mode };
    if (mode == .pack) {
        const ptr = std.heap.page_allocator.rawAlloc(region_bytes, .fromByteUnits(page), @returnAddress()) orelse return error.OutOfMemory;
        self.region = ptr[0..region_bytes];
    }

    return self;
}

pub fn allocator(self: *PlacementAllocator) std.mem.Allocator {
    if (self.mode == .none) {
        return self.child;
    }

    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

fn acquire(self: *PlacementAllocator) void {
    while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn release(self: *PlacementAllocator) void {
    self.lock.store(false, .release);
}

fn inRegion(self: *const PlacementAllocator, ptr: [*]u8) bool {
    const address = @intFromPtr(ptr);
    const start = @intFromPtr(self.region.ptr);
    return self.region.len != 0 and address >= start and address < start + self.region.len;
}

fn nextColor(self: *PlacementAllocator, len: usize) usize {
    for (&self.class_len, &self.class_next) |*class, *next| {
        if (class.* == 0) {
            class.* = len;
        }

        if (class.* == len) {
            const color = next.* % colors;
            next.* += 1;
            return color;
        }
    }

    return 0;
}

fn findTracked(self: *PlacementAllocator, address: usize) ?usize {
    for (self.tracked_ptr, 0..) |candidate, slot| {
        if (candidate == address) {
            return slot;
        }
    }

    return null;
}

fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *PlacementAllocator = @ptrCast(@alignCast(context));
    if (len < self.threshold or alignment.toByteUnits() > color_stride) {
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    self.acquire();
    defer self.release();
    self.placed += 1;

    switch (self.mode) {
        .none => unreachable,
        .color, .shift => {
            const slot = self.findTracked(0) orelse return self.child.rawAlloc(len, alignment, ret_addr);
            const base = self.child.rawAlloc(len + page, alignment, ret_addr) orelse return null;
            const ptr = base + (if (self.mode == .shift) 8 else self.nextColor(len)) * color_stride;
            self.tracked_ptr[slot] = @intFromPtr(ptr);
            self.tracked_base[slot] = @intFromPtr(base);
            self.tracked_len[slot] = len + page;
            return ptr;
        },
        .pack => {
            const start = alignment.forward(self.region_used);
            if (start + len > self.region.len) {
                return null;
            }

            self.region_used = start + len;
            return self.region.ptr + start;
        },
    }
}

fn owned(self: *PlacementAllocator, memory: []u8) bool {
    if (self.inRegion(memory.ptr)) {
        return true;
    }

    if (self.mode == .pack or memory.len < self.threshold) {
        return false;
    }

    self.acquire();
    defer self.release();
    return self.findTracked(@intFromPtr(memory.ptr)) != null;
}

fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *PlacementAllocator = @ptrCast(@alignCast(context));
    if (self.owned(memory)) {
        return false;
    }

    return self.child.rawResize(memory, alignment, new_len, ret_addr);
}

fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *PlacementAllocator = @ptrCast(@alignCast(context));
    if (self.owned(memory)) {
        return null;
    }

    return self.child.rawRemap(memory, alignment, new_len, ret_addr);
}

fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const self: *PlacementAllocator = @ptrCast(@alignCast(context));
    if (self.inRegion(memory.ptr)) {
        return;
    }

    if (self.mode != .pack and memory.len >= self.threshold) {
        self.acquire();
        const found = self.findTracked(@intFromPtr(memory.ptr));
        if (found) |slot| {
            const base: [*]u8 = @ptrFromInt(self.tracked_base[slot]);
            const total = self.tracked_len[slot];
            self.tracked_ptr[slot] = 0;
            self.release();
            self.child.rawFree(base[0..total], alignment, ret_addr);
            return;
        }

        self.release();
    }

    self.child.rawFree(memory, alignment, ret_addr);
}
