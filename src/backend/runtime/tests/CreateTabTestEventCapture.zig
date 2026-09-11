const EventCapture = @This();
const workspace_mod = @import("../../workspace/root.zig");
const create_tab_commands = @import("../application/commands/create_tab.zig");
count: usize = 0,
last: ?workspace_mod.TabCreated = null,

pub fn publisher(capture: *EventCapture) create_tab_commands.EventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: workspace_mod.TabCreated) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    capture.count += 1;
    capture.last = event;
}
