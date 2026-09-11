const WorkspaceRenamedType = @import("../../workspace/WorkspaceRenamed.zig");
const RenameWorkspaceEventPublisher = @import("../application/commands/RenameWorkspaceEventPublisher.zig");
const EventCapture = @This();

count: usize = 0,
last: ?WorkspaceRenamedType = null,

pub fn publisher(capture: *EventCapture) RenameWorkspaceEventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: WorkspaceRenamedType) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    capture.count += 1;
    capture.last = event;
}
