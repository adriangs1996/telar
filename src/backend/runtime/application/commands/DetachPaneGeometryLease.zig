const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const GeometryLease = @This();

context: *anyopaque,
release: *const fn (*anyopaque, WorkspaceLocationType) void,
