const WorkspaceCreation = @import("WorkspaceCreation.zig");
const CreationRequestEffects = @This();

context: *anyopaque,
send: *const fn (*anyopaque, WorkspaceCreation) anyerror!void,
