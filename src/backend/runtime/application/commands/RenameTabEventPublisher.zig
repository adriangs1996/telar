/// Synchronous post-commit port. Implementations may retain the event value,
/// but the erased context only has to remain valid until `publish` returns.
const EventPublisher = @This();
const workspace_mod = @import("../../../workspace/root.zig");
context: *anyopaque,
publish: *const fn (*anyopaque, workspace_mod.TabRenamed) void,
