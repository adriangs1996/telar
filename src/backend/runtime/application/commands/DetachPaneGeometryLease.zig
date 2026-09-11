const GeometryLease = @This();
const source_namespace = @import("detach_pane.zig");
context: *anyopaque,
release: *const fn (*anyopaque, source_namespace.schema.WorkspaceLocation) void,
