const StartDelivery = @This();
const source_namespace = @import("plugin_action.zig");
context: *anyopaque,
deliver: *const fn (*anyopaque, source_namespace.StartOutcome) anyerror!void,
