const PaneCapture = @This();
const source_namespace = @import("close_tab_test.zig");
const close_tab_commands = @import("../application/commands/close_tab.zig");
close_count: usize = 0,
last_location: ?source_namespace.schema.TabLocation = null,

pub fn port(capture: *PaneCapture) close_tab_commands.PaneCloser {
    return .{ .context = capture, .close_all = closeAll };
}

fn closeAll(context: *anyopaque, location: source_namespace.schema.TabLocation) void {
    const capture: *PaneCapture = @ptrCast(@alignCast(context));
    capture.close_count += 1;
    capture.last_location = location;
}
