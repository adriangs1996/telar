const FallbackEffects = @This();
const source_namespace = @import("pane_graphics.zig");
context: *anyopaque,
has_graphics: *const fn (*anyopaque, source_namespace.schema.PaneId) bool,
