const Effects = @This();
const source_namespace = @import("workspace_handoff_restoration.zig");
context: *anyopaque,
show_pane_graphics: *const fn (*anyopaque, source_namespace.schema.PaneId) anyerror!void,
