const GeometryLease = @This();
const source_namespace = @import("pane_resize.zig");
context: *anyopaque,
holds: *const fn (*anyopaque, source_namespace.schema.WorkspaceLocation) bool,
release: *const fn (*anyopaque, source_namespace.schema.WorkspaceLocation) void,
