const TabRemovedType = @import("../../../workspace/TabRemoved.zig");
/// Synchronous post-commit port. Implementations may retain the event value.
const EventPublisher = @This();

context: *anyopaque,
publish: *const fn (*anyopaque, TabRemovedType) void,
