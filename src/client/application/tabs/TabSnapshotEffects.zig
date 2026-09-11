const TabReconciliationType = @import("../../model/TabReconciliation.zig");
const Effects = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, *const TabReconciliationType) anyerror!void,
