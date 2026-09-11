const InputType = @import("../../notifications/NotificationInput.zig");
const Effects = @This();

context: *anyopaque,
synchronize_attachments: *const fn (*anyopaque) anyerror!void,
publish_alert: *const fn (*anyopaque, InputType) anyerror!void,
synchronize_animation: *const fn (*anyopaque) anyerror!void,
