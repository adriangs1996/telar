const Delivery = @import("PaneFocusDelivery.zig");
const Effects = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, Delivery) anyerror!void,
