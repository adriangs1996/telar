const DeliverPluginActionCompletionHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("PluginActionDeliveryEffects.zig");
const plugin_action = @import("plugin_action.zig");
const source_namespace = @import("plugin_action_delivery.zig");
model: *client_model.Model,
effects: Effects,

/// Maps one classified completion to a client-loop directive and commits
/// failure diagnostics before publishing their bounded notification.
///
/// ```zig
/// const directive = try handler.execute(outcome);
/// ```
pub fn execute(handler: *DeliverPluginActionCompletionHandler, outcome: plugin_action.CompletionOutcome) !plugin_action.CompletionDirective {
    const failure = source_namespace.completionFailurePublication(outcome) orelse return switch (outcome) {
        .exit => .exit_client,
        else => .continue_client,
    };

    try source_namespace.publishFailure(handler.model, handler.effects, failure);

    return .continue_client;
}
