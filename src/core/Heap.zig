const SnapshotType = @import("Snapshot.zig");
const std = @import("std");
const diagnostics = @import("diagnostics.zig");
/// Counting wrapper around the process GPA. Debug builds attribute every
/// alloc/free to the thread's current `Path`. Release returns the child
/// unchanged, so the interactive path pays nothing.
const Heap = @This();

child: std.mem.Allocator,
live_bytes: diagnostics.Counter = diagnostics.counter_init,
live_allocs: diagnostics.Counter = diagnostics.counter_init,
allocs: diagnostics.Counter = diagnostics.counter_init,
frees: diagnostics.Counter = diagnostics.counter_init,
alloc_bytes: diagnostics.Counter = diagnostics.counter_init,
path_allocs: [diagnostics.path_count]diagnostics.Counter = @splat(diagnostics.counter_init),
path_alloc_bytes: [diagnostics.path_count]diagnostics.Counter = @splat(diagnostics.counter_init),
interactive_vt_allocs: diagnostics.Counter = diagnostics.counter_init,
interactive_vt_alloc_bytes: diagnostics.Counter = diagnostics.counter_init,

pub const Snapshot = @import("Snapshot.zig");

pub fn init(child: std.mem.Allocator) Heap {
    return .{ .child = child };
}

pub fn allocator(heap: *Heap) std.mem.Allocator {
    if (!diagnostics.enabled) {
        return heap.child;
    }
    return .{
        .ptr = heap,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

pub fn snapshot(heap: *const Heap) SnapshotType {
    return .{
        .live_bytes = diagnostics.load(&heap.live_bytes),
        .live_allocs = diagnostics.load(&heap.live_allocs),
        .allocs = diagnostics.load(&heap.allocs),
        .frees = diagnostics.load(&heap.frees),
        .alloc_bytes = diagnostics.load(&heap.alloc_bytes),
        .interactive_allocs = diagnostics.load(&heap.path_allocs[@intFromEnum(diagnostics.Path.interactive)]),
        .interactive_alloc_bytes = diagnostics.load(&heap.path_alloc_bytes[@intFromEnum(diagnostics.Path.interactive)]),
        .interactive_vt_allocs = diagnostics.load(&heap.interactive_vt_allocs),
        .interactive_vt_alloc_bytes = diagnostics.load(&heap.interactive_vt_alloc_bytes),
        .media_allocs = diagnostics.load(&heap.path_allocs[@intFromEnum(diagnostics.Path.media)]),
        .media_alloc_bytes = diagnostics.load(&heap.path_alloc_bytes[@intFromEnum(diagnostics.Path.media)]),
        .observation_allocs = diagnostics.load(&heap.path_allocs[@intFromEnum(diagnostics.Path.observation)]),
        .observation_alloc_bytes = diagnostics.load(&heap.path_alloc_bytes[@intFromEnum(diagnostics.Path.observation)]),
        .other_allocs = diagnostics.load(&heap.path_allocs[@intFromEnum(diagnostics.Path.other)]),
        .other_alloc_bytes = diagnostics.load(&heap.path_alloc_bytes[@intFromEnum(diagnostics.Path.other)]),
    };
}

fn recordAlloc(heap: *Heap, len: usize) void {
    diagnostics.add(&heap.live_bytes, len);
    diagnostics.add(&heap.live_allocs, 1);
    diagnostics.add(&heap.allocs, 1);
    diagnostics.add(&heap.alloc_bytes, len);
    const path = @intFromEnum(diagnostics.current_path);
    diagnostics.add(&heap.path_allocs[path], 1);
    diagnostics.add(&heap.path_alloc_bytes[path], len);
    if (diagnostics.current_path == .interactive and diagnostics.terminal_allocation_scope) {
        diagnostics.add(&heap.interactive_vt_allocs, 1);
        diagnostics.add(&heap.interactive_vt_alloc_bytes, len);
    }
}

fn recordGrow(heap: *Heap, delta: usize) void {
    diagnostics.add(&heap.live_bytes, delta);
    diagnostics.add(&heap.alloc_bytes, delta);
    diagnostics.add(&heap.path_alloc_bytes[@intFromEnum(diagnostics.current_path)], delta);
    if (diagnostics.current_path == .interactive and diagnostics.terminal_allocation_scope) {
        diagnostics.add(&heap.interactive_vt_alloc_bytes, delta);
    }
}

fn recordShrink(heap: *Heap, delta: usize) void {
    diagnostics.sub(&heap.live_bytes, delta);
}

fn recordFree(heap: *Heap, len: usize) void {
    diagnostics.sub(&heap.live_bytes, len);
    diagnostics.sub(&heap.live_allocs, 1);
    diagnostics.add(&heap.frees, 1);
}

// codestyle: allow(maximum-parameter-count)
fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const heap: *Heap = @ptrCast(@alignCast(context));
    const result = heap.child.rawAlloc(len, alignment, ret_addr) orelse return null;
    heap.recordAlloc(len);
    return result;
}

// codestyle: allow(maximum-parameter-count)
fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const heap: *Heap = @ptrCast(@alignCast(context));
    if (!heap.child.rawResize(memory, alignment, new_len, ret_addr)) {
        return false;
    }
    if (new_len > memory.len) {
        heap.recordGrow(new_len - memory.len);
    }
    if (new_len < memory.len) {
        heap.recordShrink(memory.len - new_len);
    }
    return true;
}

// codestyle: allow(maximum-parameter-count)
fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const heap: *Heap = @ptrCast(@alignCast(context));
    const result = heap.child.rawRemap(memory, alignment, new_len, ret_addr) orelse
        return null;
    if (new_len > memory.len) {
        heap.recordGrow(new_len - memory.len);
    }
    if (new_len < memory.len) {
        heap.recordShrink(memory.len - new_len);
    }
    return result;
}

// codestyle: allow(maximum-parameter-count)
fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const heap: *Heap = @ptrCast(@alignCast(context));
    heap.child.rawFree(memory, alignment, ret_addr);
    heap.recordFree(memory.len);
}
