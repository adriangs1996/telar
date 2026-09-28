//! The process allocator of musl release builds: power-of-two size classes
//! carved from 64 KiB slabs, one free list per thread slot, and a slab mapped
//! only after the other slots came up empty for that class.

const std = @import("std");

const SlabHeap = @import("SlabHeap.zig");

var process_heap: SlabHeap = .{};

/// The process-wide slab heap. Every thread may use it.
///
/// ```zig
/// const bytes = try slabheap.allocator.alloc(u8, 256);
/// defer slabheap.allocator.free(bytes);
/// ```
pub const allocator: std.mem.Allocator = .{
    .ptr = &process_heap,
    .vtable = &SlabHeap.vtable,
};

test {
    _ = @import("SlabHeap.zig");
}
