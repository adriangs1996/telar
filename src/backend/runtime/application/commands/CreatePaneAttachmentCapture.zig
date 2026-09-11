const AttachmentCapture = @This();
const pane_mod = @import("../../../pane/root.zig");
const PaneAttachment = @import("CreatePanePaneAttachment.zig");
failure: ?anyerror = null,
event_count: ?*const usize = null,
call_count: usize = 0,
last: ?pane_mod.PaneLaunched = null,
event_observed_before_attach: bool = false,

pub fn port(capture: *AttachmentCapture) PaneAttachment {
    return .{ .context = capture, .attach = attach };
}

fn attach(context: *anyopaque, launched: pane_mod.PaneLaunched) !void {
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
