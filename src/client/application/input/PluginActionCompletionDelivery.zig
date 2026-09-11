const plugin_action = @import("plugin_action.zig");
const CompletionDelivery = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, plugin_action.CompletionOutcome) anyerror!plugin_action.CompletionDirective,
