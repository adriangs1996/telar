const TabMovedType = @import("../../../workspace/TabMoved.zig");
const EventPublisher = @This();

context: *anyopaque,
publish: *const fn (*anyopaque, TabMovedType) void,
