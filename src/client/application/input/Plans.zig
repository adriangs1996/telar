const Plans = @This();
const source_namespace = @import("pane_mouse.zig");
const Resolved = @import("Resolved.zig");
context: *anyopaque,
resolve: *const fn (*anyopaque, source_namespace.Command) ?Resolved,
