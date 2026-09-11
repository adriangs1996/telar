const WorkspaceCreatedType = @import("../../../workspace/WorkspaceCreated.zig");
const EventPublisher = @This();

context: *anyopaque,
publish: *const fn (*anyopaque, WorkspaceCreatedType) void,
