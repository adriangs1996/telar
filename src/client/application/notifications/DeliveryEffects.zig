const InputType = @import("../../notifications/NotificationInput.zig");
const DeliveryEffects = @This();

context: *anyopaque,
publish: *const fn (*anyopaque, InputType) anyerror!void,
