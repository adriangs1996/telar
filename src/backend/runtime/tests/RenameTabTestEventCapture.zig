const EventCapture = @This();
const workspace_mod = @import("../../workspace/root.zig");
const rename_tab_commands = @import("../application/commands/rename_tab.zig");
count: usize = 0,
last: ?workspace_mod.TabRenamed = null,

pub fn publisher(capture: *EventCapture) rename_tab_commands.EventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: workspace_mod.TabRenamed) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    capture.count += 1;
    capture.last = event;
}
