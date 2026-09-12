const PaneFrameRecoveryType = @import("../../model/PaneFrameRecovery.zig");
const PaneFrameCommitType = @import("../../model/PaneFrameCommit.zig");
const FrameAckType = @import("telar-core").FrameAck;
const PaneFrameEffects = @This();

context: *anyopaque,
recover: *const fn (*anyopaque, PaneFrameRecoveryType) anyerror!void,
acknowledge: *const fn (*anyopaque, FrameAckType) anyerror!void,
deliver: *const fn (*anyopaque, PaneFrameCommitType) anyerror!void,
