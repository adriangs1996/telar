/// Synchronous post-commit port. Implementations may retain the event value.
const EventPublisher = @This();
const workspace_mod = @import("../../../workspace/root.zig");
context: *anyopaque,
publish: *const fn (*anyopaque, workspace_mod.TabRemoved) void,
