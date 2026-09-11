const GeometryLease = @This();
const source_namespace = @import("create_workspace.zig");
context: *anyopaque,
acquire: *const fn (*anyopaque, source_namespace.schema.WorkspaceLocation) bool,
release: *const fn (*anyopaque, source_namespace.schema.WorkspaceLocation) void,
