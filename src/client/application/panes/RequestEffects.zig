const RequestEffects = @This();
const client_model = @import("../../root.zig").model;
context: *anyopaque,
resize: *const fn (*anyopaque, client_model.PaneResize) anyerror!void,
send: *const fn (*anyopaque, client_model.PaneSplitPlan) anyerror!void,
