const EventPublisher = @This();
const workspace_mod = @import("../../../workspace/root.zig");
context: *anyopaque,
publish: *const fn (*anyopaque, workspace_mod.TabMoved) void,
