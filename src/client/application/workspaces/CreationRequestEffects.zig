const CreationRequestEffects = @This();
const WorkspaceCreation = @import("WorkspaceCreation.zig");
context: *anyopaque,
send: *const fn (*anyopaque, WorkspaceCreation) anyerror!void,
