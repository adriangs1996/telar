const Effects = @This();
const notification_capability = @import("../../root.zig").notifications;
context: *anyopaque,
publish_notification: *const fn (*anyopaque, notification_capability.Input) anyerror!void,
