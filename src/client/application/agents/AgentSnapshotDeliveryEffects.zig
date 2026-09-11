const Effects = @This();
const notification_capability = @import("../../root.zig").notifications;
context: *anyopaque,
synchronize_attachments: *const fn (*anyopaque) anyerror!void,
publish_alert: *const fn (*anyopaque, notification_capability.Input) anyerror!void,
synchronize_animation: *const fn (*anyopaque) anyerror!void,
