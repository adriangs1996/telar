const PaneResizeType = @import("telar-core").PaneResize;
const PaneSplitPlanType = @import("../../model/PaneSplitPlan.zig");
const RequestEffects = @This();

context: *anyopaque,
resize: *const fn (*anyopaque, PaneResizeType) anyerror!void,
send: *const fn (*anyopaque, PaneSplitPlanType) anyerror!void,
