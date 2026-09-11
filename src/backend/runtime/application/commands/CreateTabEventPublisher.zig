const TabCreatedType = @import("../../../workspace/TabCreated.zig");
/// Synchronous post-commit port. Implementations may retain the owned event.
const EventPublisher = @This();

context: *anyopaque,
publish: *const fn (*anyopaque, TabCreatedType) void,
