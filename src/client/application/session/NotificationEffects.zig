const InputType = @import("../../notifications/NotificationInput.zig");
const NotificationEffects = @This();

context: *anyopaque,
publish: *const fn (*anyopaque, InputType) anyerror!void,
