const PaneResizeType = @import("telar-core").PaneResize;
const RecoveryEffects = @This();

context: *anyopaque,
resize: *const fn (*anyopaque, PaneResizeType) anyerror!void,
