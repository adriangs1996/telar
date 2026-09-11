const TabCreationType = @import("../../model/TabCreation.zig");
const ConfirmationDelivery = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, TabCreationType) anyerror!void,
