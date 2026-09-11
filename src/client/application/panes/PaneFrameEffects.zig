const PaneFrameRecoveryType = @import("../../model/PaneFrameRecovery.zig");
const PaneFrameCommitType = @import("../../model/PaneFrameCommit.zig");
const PaneFrameEffects = @This();

context: *anyopaque,
recover: *const fn (*anyopaque, PaneFrameRecoveryType) anyerror!void,
deliver: *const fn (*anyopaque, PaneFrameCommitType) anyerror!void,
