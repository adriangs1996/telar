const PaneIdType = @import("telar-core").PaneId;
const ClientAttachment = @import("ClientAttachment.zig");
const CreateWorkspaceLaunchedPane = @import("CreateWorkspaceLaunchedPane.zig");
const AttachmentCapture = @This();

failure: ?anyerror = null,
event_count: ?*const usize = null,
call_count: usize = 0,
last_pane_id: PaneIdType = .invalid,
event_observed_before_replace: bool = false,

pub fn port(capture: *AttachmentCapture) ClientAttachment {
    return .{ .context = capture, .replace = replace };
}

fn replace(context: *anyopaque, pane: CreateWorkspaceLaunchedPane) !void {
    const capture: *AttachmentCapture = @ptrCast(@alignCast(context));
    capture.call_count += 1;
    capture.last_pane_id = pane.id;

    if (capture.event_count) |count| {
        capture.event_observed_before_replace = count.* == 1;
    }

    if (capture.failure) |failure| {
        return failure;
    }
}
