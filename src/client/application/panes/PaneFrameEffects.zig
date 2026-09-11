const PaneFrameEffects = @This();
const client_model = @import("../../root.zig").model;
context: *anyopaque,
recover: *const fn (*anyopaque, client_model.PaneFrameRecovery) anyerror!void,
deliver: *const fn (*anyopaque, client_model.PaneFrameCommit) anyerror!void,
