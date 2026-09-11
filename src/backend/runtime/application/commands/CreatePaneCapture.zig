const TabLocationType = @import("telar-core").TabLocation;
const TabPanes = @import("TabPanes.zig");
const PaneCapture = @This();

has_running: bool = true,
call_count: usize = 0,
last_location: ?TabLocationType = null,

pub fn port(capture: *PaneCapture) TabPanes {
    return .{ .context = capture, .has_running = hasRunning };
}

fn hasRunning(context: *anyopaque, location: TabLocationType) bool {
    const capture: *PaneCapture = @ptrCast(@alignCast(context));
    capture.call_count += 1;
    capture.last_location = location;
    return capture.has_running;
}
