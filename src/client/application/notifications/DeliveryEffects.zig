const DeliveryEffects = @This();
const notification_capability = @import("../../root.zig").notifications;
context: *anyopaque,
publish: *const fn (*anyopaque, notification_capability.Input) anyerror!void,
