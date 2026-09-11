const AttachmentCapture = @This();
const source_namespace = @import("create_workspace.zig");
const ClientAttachment = @import("ClientAttachment.zig");
const LaunchedPane = @import("CreateWorkspaceLaunchedPane.zig");
failure: ?anyerror = null,
event_count: ?*const usize = null,
call_count: usize = 0,
last_pane_id: source_namespace.schema.PaneId = .invalid,
event_observed_before_replace: bool = false,

pub fn port(capture: *AttachmentCapture) ClientAttachment {
    return .{ .context = capture, .replace = replace };
}

fn replace(context: *anyopaque, pane: LaunchedPane) !void {
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
