const WorkspaceRenamedType = @import("../../../workspace/WorkspaceRenamed.zig");
const EventPublisher = @This();

context: *anyopaque,
publish: *const fn (*anyopaque, WorkspaceRenamedType) void,
