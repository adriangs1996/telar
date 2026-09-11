const Effects = @This();
const Delivery = @import("Delivery.zig");
context: *anyopaque,
deliver: *const fn (*anyopaque, Delivery) anyerror!void,
