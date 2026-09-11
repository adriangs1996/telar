const HandoffRequestEffects = @This();
const WorkspaceHandoff = @import("WorkspaceHandoff.zig");
const client_model = @import("../../root.zig").model;
context: *anyopaque,
send: *const fn (*anyopaque, WorkspaceHandoff) anyerror!void,
release: *const fn (*anyopaque, *const client_model.WorkspaceDeparture) void,
