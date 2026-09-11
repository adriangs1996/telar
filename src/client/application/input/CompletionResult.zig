const plugin_action = @import("plugin_action.zig");
const CompletionResult = @This();

outcome: plugin_action.CompletionOutcome,
directive: plugin_action.CompletionDirective,
