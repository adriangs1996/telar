const PluginExecutionType = @import("../../model/PluginExecution.zig");
const StartEffects = @This();

context: *anyopaque,
prepare: *const fn (*anyopaque) anyerror!void,
schedule: *const fn (*anyopaque, PluginExecutionType) anyerror!void,
