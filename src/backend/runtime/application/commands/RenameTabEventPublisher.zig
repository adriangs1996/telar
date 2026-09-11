const TabRenamedType = @import("../../../workspace/TabRenamed.zig");
/// Synchronous post-commit port. Implementations may retain the event value,
/// but the erased context only has to remain valid until `publish` returns.
const EventPublisher = @This();

context: *anyopaque,
publish: *const fn (*anyopaque, TabRenamedType) void,
