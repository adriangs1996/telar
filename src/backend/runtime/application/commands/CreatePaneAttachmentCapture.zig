const PaneLaunchedType = @import("../../../pane/PaneLaunched.zig");
const CreatePaneAttachment = @import("CreatePaneAttachment.zig");
const AttachmentCapture = @This();

failure: ?anyerror = null,
event_count: ?*const usize = null,
call_count: usize = 0,
last: ?PaneLaunchedType = null,
event_observed_before_attach: bool = false,

pub fn port(capture: *AttachmentCapture) CreatePaneAttachment {
    return .{ .context = capture, .attach = attach };
}

fn attach(context: *anyopaque, launched: PaneLaunchedType) !void {
    const capture: *AttachmentCapture = @ptrCast(@alignCast(context));
    capture.call_count += 1;
    capture.last = launched;

    if (capture.event_count) |count| {
        capture.event_observed_before_attach = count.* == 1;
    }

    if (capture.failure) |failure| {
        return failure;
    }
}
