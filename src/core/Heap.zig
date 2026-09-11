/// Counting wrapper around the process GPA. Debug builds attribute every
/// alloc/free to the thread's current `Path`. Release returns the child
/// unchanged, so the interactive path pays nothing.
const Heap = @This();
const source_namespace = @import("diagnostics.zig");
const std = @import("std");
child: source_namespace.Allocator,
live_bytes: source_namespace.Counter = source_namespace.counter_init,
live_allocs: source_namespace.Counter = source_namespace.counter_init,
allocs: source_namespace.Counter = source_namespace.counter_init,
frees: source_namespace.Counter = source_namespace.counter_init,
alloc_bytes: source_namespace.Counter = source_namespace.counter_init,
path_allocs: [source_namespace.path_count]source_namespace.Counter = @splat(source_namespace.counter_init),
path_alloc_bytes: [source_namespace.path_count]source_namespace.Counter = @splat(source_namespace.counter_init),
interactive_vt_allocs: source_namespace.Counter = source_namespace.counter_init,
interactive_vt_alloc_bytes: source_namespace.Counter = source_namespace.counter_init,

pub const Snapshot = struct {
    live_bytes: u64 = 0,
    live_allocs: u64 = 0,
    allocs: u64 = 0,
    frees: u64 = 0,
    alloc_bytes: u64 = 0,
    interactive_allocs: u64 = 0,
    interactive_alloc_bytes: u64 = 0,
    interactive_vt_allocs: u64 = 0,
    interactive_vt_alloc_bytes: u64 = 0,
    media_allocs: u64 = 0,
    media_alloc_bytes: u64 = 0,
    observation_allocs: u64 = 0,
    observation_alloc_bytes: u64 = 0,
    other_allocs: u64 = 0,
    other_alloc_bytes: u64 = 0,
};

pub fn init(child: source_namespace.Allocator) Heap {
    return .{ .child = child };
}

pub fn allocator(heap: *Heap) source_namespace.Allocator {
    if (!source_namespace.enabled) {
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

pub fn snapshot(heap: *const Heap) Snapshot {
    return .{
        .live_bytes = source_namespace.load(&heap.live_bytes),
        .live_allocs = source_namespace.load(&heap.live_allocs),
        .allocs = source_namespace.load(&heap.allocs),
        .frees = source_namespace.load(&heap.frees),
        .alloc_bytes = source_namespace.load(&heap.alloc_bytes),
        .interactive_allocs = source_namespace.load(&heap.path_allocs[@intFromEnum(source_namespace.Path.interactive)]),
        .interactive_alloc_bytes = source_namespace.load(&heap.path_alloc_bytes[@intFromEnum(source_namespace.Path.interactive)]),
        .interactive_vt_allocs = source_namespace.load(&heap.interactive_vt_allocs),
        .interactive_vt_alloc_bytes = source_namespace.load(&heap.interactive_vt_alloc_bytes),
        .media_allocs = source_namespace.load(&heap.path_allocs[@intFromEnum(source_namespace.Path.media)]),
        .media_alloc_bytes = source_namespace.load(&heap.path_alloc_bytes[@intFromEnum(source_namespace.Path.media)]),
        .observation_allocs = source_namespace.load(&heap.path_allocs[@intFromEnum(source_namespace.Path.observation)]),
        .observation_alloc_bytes = source_namespace.load(&heap.path_alloc_bytes[@intFromEnum(source_namespace.Path.observation)]),
        .other_allocs = source_namespace.load(&heap.path_allocs[@intFromEnum(source_namespace.Path.other)]),
        .other_alloc_bytes = source_namespace.load(&heap.path_alloc_bytes[@intFromEnum(source_namespace.Path.other)]),
    };
}

fn recordAlloc(heap: *Heap, len: usize) void {
    source_namespace.add(&heap.live_bytes, len);
    source_namespace.add(&heap.live_allocs, 1);
    source_namespace.add(&heap.allocs, 1);
    source_namespace.add(&heap.alloc_bytes, len);
    const path = @intFromEnum(source_namespace.current_path);
    source_namespace.add(&heap.path_allocs[path], 1);
    source_namespace.add(&heap.path_alloc_bytes[path], len);
    if (source_namespace.current_path == .interactive and source_namespace.terminal_allocation_scope) {
        source_namespace.add(&heap.interactive_vt_allocs, 1);
        source_namespace.add(&heap.interactive_vt_alloc_bytes, len);
    }
}

fn recordGrow(heap: *Heap, delta: usize) void {
    source_namespace.add(&heap.live_bytes, delta);
    source_namespace.add(&heap.alloc_bytes, delta);
    source_namespace.add(&heap.path_alloc_bytes[@intFromEnum(source_namespace.current_path)], delta);
    if (source_namespace.current_path == .interactive and source_namespace.terminal_allocation_scope) {
        source_namespace.add(&heap.interactive_vt_alloc_bytes, delta);
    }
}

fn recordShrink(heap: *Heap, delta: usize) void {
    source_namespace.sub(&heap.live_bytes, delta);
}

fn recordFree(heap: *Heap, len: usize) void {
    source_namespace.sub(&heap.live_bytes, len);
    source_namespace.sub(&heap.live_allocs, 1);
    source_namespace.add(&heap.frees, 1);
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
