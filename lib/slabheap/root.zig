//! A process-wide, thread-safe allocator for release builds whose libc
//! allocator strands freed memory: slots of power-of-two size classes carved
//! from 64 KiB slabs, one free list per thread slot, and a slab mapped only
//! after every slot came up empty for that class.

pub const allocator = @import("slab_heap.zig").allocator;

test {
    _ = @import("slab_heap.zig");
}
