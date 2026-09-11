const ModelType = @import("../../model/Model.zig");
const PluginActionDeliveryEffects = @import("PluginActionDeliveryEffects.zig");
const plugin_action = @import("plugin_action.zig");
const plugin_action_delivery = @import("plugin_action_delivery.zig");
const DeliverPluginActionCompletionHandler = @This();

model: *ModelType,
effects: PluginActionDeliveryEffects,

/// Maps one classified completion to a client-loop directive and commits
/// failure diagnostics before publishing their bounded notification.
///
/// ```zig
/// const directive = try handler.execute(outcome);
/// ```
pub fn execute(handler: *DeliverPluginActionCompletionHandler, outcome: plugin_action.CompletionOutcome) !plugin_action.CompletionDirective {
    const failure = plugin_action_delivery.completionFailurePublication(outcome) orelse return switch (outcome) {
        .exit => .exit_client,
        else => .continue_client,
    };

    try plugin_action_delivery.publishFailure(handler.model, handler.effects, failure);

    return .continue_client;
}
