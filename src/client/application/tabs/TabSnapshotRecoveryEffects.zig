const Effects = @This();
const source_namespace = @import("tab_snapshot_recovery.zig");
context: *anyopaque,
pending: *const fn (*anyopaque) bool,
request: *const fn (*anyopaque, source_namespace.schema.TabLocation) anyerror!void,
