const StopRequestedType = @import("../../lifecycle/StopRequested.zig");
const Notifications = @This();

context: *anyopaque,
publish_fn: *const fn (*anyopaque, StopRequestedType) void,

/// Publishes the committed shutdown event to runtime delivery.
///
/// ```zig
/// notifications.publish(event);
/// ```
pub fn publish(notifications: Notifications, event: StopRequestedType) void {
    notifications.publish_fn(notifications.context, event);
}
