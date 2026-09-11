const WorkspaceHandoff = @import("WorkspaceHandoff.zig");
const WorkspaceDepartureType = @import("../../model/WorkspaceDeparture.zig");
const HandoffRequestEffects = @This();

context: *anyopaque,
send: *const fn (*anyopaque, WorkspaceHandoff) anyerror!void,
release: *const fn (*anyopaque, *const WorkspaceDepartureType) void,
