const notifications = @import("../notifications/notifications.zig");
const NotificationActivation = @This();

target: notifications.Target,
notifications_revision: u64,
