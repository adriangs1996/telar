const EventCapture = @This();
const workspace_mod = @import("../../../workspace/root.zig");
const EventPublisher = @import("RenameWorkspaceEventPublisher.zig");
const std = @import("std");
reader: workspace_mod.Reader,
count: usize = 0,
last: ?workspace_mod.WorkspaceRenamed = null,
observed_committed_state: bool = false,

pub fn publisher(capture: *EventCapture) EventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: workspace_mod.WorkspaceRenamed) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    const committed_name = capture.reader.workspaceName(event.location) orelse return;

    capture.count += 1;
    capture.last = event;
    capture.observed_committed_state = std.mem.eql(u8, committed_name, event.nameSlice());
}
