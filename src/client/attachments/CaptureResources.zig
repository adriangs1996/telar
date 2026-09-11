/// Owns only the result pointer that can outlive a cancelled capture worker.
/// The client model owns the active capture identity and target.
const CaptureResources = @This();
const Capture = @import("Capture.zig");
const std = @import("std");
orphan: ?*Capture = null,

/// Transfers one completed worker result to the client event handler.
///
/// ```zig
/// const owned = resources.take(completed);
/// ```
pub fn take(resources: *CaptureResources, capture: *Capture) *Capture {
    std.debug.assert(resources.orphan == capture);
    resources.orphan = null;
    return capture;
}

/// Frees a result published before its worker was cancelled.
///
/// ```zig
/// defer resources.deinit(gpa);
/// ```
pub fn deinit(resources: *CaptureResources, gpa: std.mem.Allocator) void {
    if (resources.orphan) |capture| {
        capture.deinit(gpa);
    }

    resources.* = .{};
}
