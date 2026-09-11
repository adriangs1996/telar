const ReaderType = @import("../../../workspace/Reader.zig");
const WorkspaceRenamedType = @import("../../../workspace/WorkspaceRenamed.zig");
const RenameWorkspaceEventPublisher = @import("RenameWorkspaceEventPublisher.zig");
const std = @import("std");
const EventCapture = @This();

reader: ReaderType,
count: usize = 0,
last: ?WorkspaceRenamedType = null,
observed_committed_state: bool = false,

pub fn publisher(capture: *EventCapture) RenameWorkspaceEventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: WorkspaceRenamedType) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    const committed_name = capture.reader.workspaceName(event.location) orelse return;

    capture.count += 1;
    capture.last = event;
    capture.observed_committed_state = std.mem.eql(u8, committed_name, event.nameSlice());
}
