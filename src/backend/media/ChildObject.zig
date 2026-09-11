const std = @import("std");
/// A child's shared object mapped read-only for one copy out of it.
const ChildObject = @This();

pixels: []align(std.heap.page_size_min) u8,

/// Unmaps the object; the name was already unlinked, as the protocol
/// asks of whoever consumes a `t=s` transmission.
pub fn close(object: ChildObject) void {
    std.posix.munmap(object.pixels);
}
