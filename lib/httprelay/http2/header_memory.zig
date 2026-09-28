//! nghttp2's allocation hooks over a Zig allocator, so the header inflater's
//! table comes from the relay's allocator instead of libc's `malloc`.
const std = @import("std");
const cblocks = @import("cblocks");
const relay = @import("relay.zig");

/// Hooks that allocate from `allocator`. nghttp2 keeps a pointer to the
/// returned value, so it and `allocator` must outlive every inflater made
/// with them.
///
/// ```zig
/// var memory = header_memory.of(&gpa);
/// var observer = Observer.init(&memory, routes, .request);
/// ```
pub fn of(allocator: *const std.mem.Allocator) relay.c.nghttp2_mem {
    return .{
        .mem_user_data = @constCast(allocator),
        .malloc = &allocate,
        .free = &release,
        .calloc = &allocateZeroed,
        .realloc = &reallocate,
    };
}

fn allocate(bytes: usize, user_data: ?*anyopaque) callconv(.c) ?*anyopaque {
    return cblocks.alloc(owner(user_data), bytes);
}

fn release(pointer: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    cblocks.free(owner(user_data), pointer);
}

fn allocateZeroed(count: usize, size: usize, user_data: ?*anyopaque) callconv(.c) ?*anyopaque {
    return cblocks.zeroed(owner(user_data), count, size);
}

fn reallocate(pointer: ?*anyopaque, bytes: usize, user_data: ?*anyopaque) callconv(.c) ?*anyopaque {
    return cblocks.realloc(owner(user_data), pointer, bytes);
}

fn owner(user_data: ?*anyopaque) std.mem.Allocator {
    const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(user_data.?));
    return allocator.*;
}

test "an inflater allocates its table from the hooks and returns it on delete" {
    var counting: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    const allocator = counting.allocator();
    var memory = of(&allocator);

    var inflater: ?*relay.c.nghttp2_hd_inflater = null;
    try std.testing.expectEqual(@as(c_int, 0), relay.c.nghttp2_hd_inflate_new2(&inflater, &memory));
    try std.testing.expect(counting.allocations > 0);

    relay.c.nghttp2_hd_inflate_del(inflater);
    try std.testing.expectEqual(counting.allocations, counting.deallocations);
    try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
}
