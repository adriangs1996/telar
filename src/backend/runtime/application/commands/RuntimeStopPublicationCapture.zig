const StateType = @import("../../lifecycle/State.zig");
const StopRequestedType = @import("../../lifecycle/StopRequested.zig");
const Notifications = @import("Notifications.zig");
const PublicationCapture = @This();

shutdown: *const StateType,
calls: usize = 0,
event: ?StopRequestedType = null,
observed_committed_state: bool = false,

pub fn notifications(capture: *PublicationCapture) Notifications {
    return .{ .context = capture, .publish_fn = publish };
}

fn publish(context: *anyopaque, event: StopRequestedType) void {
    const capture: *PublicationCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.event = event;
    capture.observed_committed_state = capture.shutdown.isRequested();
}
