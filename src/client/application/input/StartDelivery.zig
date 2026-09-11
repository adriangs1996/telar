const plugin_action = @import("plugin_action.zig");
const StartDelivery = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, plugin_action.StartOutcome) anyerror!void,
