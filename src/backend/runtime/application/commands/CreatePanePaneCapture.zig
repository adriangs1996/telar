const PaneCapture = @This();
const source_namespace = @import("create_pane.zig");
const TabPanes = @import("TabPanes.zig");
has_running: bool = true,
call_count: usize = 0,
last_location: ?source_namespace.schema.TabLocation = null,

pub fn port(capture: *PaneCapture) TabPanes {
    return .{ .context = capture, .has_running = hasRunning };
}

fn hasRunning(context: *anyopaque, location: source_namespace.schema.TabLocation) bool {
    const capture: *PaneCapture = @ptrCast(@alignCast(context));
    capture.call_count += 1;
    capture.last_location = location;
    return capture.has_running;
}
