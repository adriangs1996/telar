const NotificationEffects = @This();
const notifications = @import("../../root.zig").notifications;
context: *anyopaque,
publish: *const fn (*anyopaque, notifications.Input) anyerror!void,
