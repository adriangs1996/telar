const notifications = @import("../notifications/notifications.zig");
const NotificationPublication = @This();

id: notifications.Id,
notifications_revision: u64,
