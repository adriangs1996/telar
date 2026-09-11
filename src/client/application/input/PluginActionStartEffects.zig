const StartEffects = @This();
const client_model = @import("../../root.zig").model;
context: *anyopaque,
prepare: *const fn (*anyopaque) anyerror!void,
schedule: *const fn (*anyopaque, client_model.PluginExecution) anyerror!void,
