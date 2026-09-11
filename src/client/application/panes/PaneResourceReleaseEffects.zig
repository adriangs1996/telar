const Effects = @This();
const source_namespace = @import("pane_resource_release.zig");
context: *anyopaque,
clear_graphics: *const fn (*anyopaque, source_namespace.schema.PaneId) void,
