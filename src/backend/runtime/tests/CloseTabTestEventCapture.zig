const EventCapture = @This();
const workspace_mod = @import("../../workspace/root.zig");
const close_tab_commands = @import("../application/commands/close_tab.zig");
count: usize = 0,
last: ?workspace_mod.TabRemoved = null,

pub fn publisher(capture: *EventCapture) close_tab_commands.EventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: workspace_mod.TabRemoved) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    capture.count += 1;
    capture.last = event;
}
