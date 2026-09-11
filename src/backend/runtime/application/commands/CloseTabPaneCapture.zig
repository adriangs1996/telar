const TabLocationType = @import("telar-core").TabLocation;
const PaneCloser = @import("PaneCloser.zig");
const PaneCapture = @This();

close_count: usize = 0,
last_location: ?TabLocationType = null,

pub fn port(capture: *PaneCapture) PaneCloser {
    return .{ .context = capture, .close_all = closeAll };
}

fn closeAll(context: *anyopaque, location: TabLocationType) void {
    const capture: *PaneCapture = @ptrCast(@alignCast(context));
    capture.close_count += 1;
    capture.last_location = location;
}
