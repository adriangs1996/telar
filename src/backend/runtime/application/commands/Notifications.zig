const Notifications = @This();
const shutdown_mod = @import("../../lifecycle/root.zig").shutdown_authority;
context: *anyopaque,
publish_fn: *const fn (*anyopaque, shutdown_mod.StopRequested) void,

/// Publishes the committed shutdown event to runtime delivery.
///
/// ```zig
/// notifications.publish(event);
/// ```
pub fn publish(notifications: Notifications, event: shutdown_mod.StopRequested) void {
    notifications.publish_fn(notifications.context, event);
}
