const PublicationCapture = @This();
const shutdown_mod = @import("../../lifecycle/root.zig").shutdown_authority;
const Notifications = @import("Notifications.zig");
shutdown: *const shutdown_mod.State,
calls: usize = 0,
event: ?shutdown_mod.StopRequested = null,
observed_committed_state: bool = false,

pub fn notifications(capture: *PublicationCapture) Notifications {
    return .{ .context = capture, .publish_fn = publish };
}

fn publish(context: *anyopaque, event: shutdown_mod.StopRequested) void {
    const capture: *PublicationCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.event = event;
    capture.observed_committed_state = capture.shutdown.isRequested();
}
