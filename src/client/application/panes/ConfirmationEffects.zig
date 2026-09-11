const PaneSplitCommitType = @import("../../model/PaneSplitCommit.zig");
const ConfirmationEffects = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, PaneSplitCommitType) anyerror!void,
