const EventCapture = @This();
const workspace_mod = @import("../../workspace/root.zig");
const move_tab_commands = @import("../application/commands/move_tab.zig");
count: usize = 0,
last: ?workspace_mod.TabMoved = null,

pub fn publisher(capture: *EventCapture) move_tab_commands.EventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: workspace_mod.TabMoved) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    capture.count += 1;
    capture.last = event;
}
