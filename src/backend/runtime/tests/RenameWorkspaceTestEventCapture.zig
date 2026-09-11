const EventCapture = @This();
const workspace_mod = @import("../../workspace/root.zig");
const rename_workspace_commands = @import("../application/commands/rename_workspace.zig");
count: usize = 0,
last: ?workspace_mod.WorkspaceRenamed = null,

pub fn publisher(capture: *EventCapture) rename_workspace_commands.EventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: workspace_mod.WorkspaceRenamed) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    capture.count += 1;
    capture.last = event;
}
