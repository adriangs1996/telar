const InputType = @import("../../notifications/NotificationInput.zig");
const Effects = @This();

context: *anyopaque,
publish_notification: *const fn (*anyopaque, InputType) anyerror!void,
