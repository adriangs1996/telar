const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const GeometryLease = @This();

context: *anyopaque,
holds: *const fn (*anyopaque, WorkspaceLocationType) bool,
release: *const fn (*anyopaque, WorkspaceLocationType) void,
