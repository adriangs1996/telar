const notification_capability = @import("../../notifications/notifications.zig");
const InteractionCommand = @This();

id: notification_capability.Id,
now_ns: u64,
