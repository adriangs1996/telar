const ModelType = @import("../../model/Model.zig");
const PluginActionDeliveryEffects = @import("PluginActionDeliveryEffects.zig");
const plugin_action = @import("plugin_action.zig");
const plugin_action_delivery = @import("plugin_action_delivery.zig");
const DeliverPluginActionStartHandler = @This();

model: *ModelType,
effects: PluginActionDeliveryEffects,

/// Keeps quiet start outcomes silent and commits rejected-action
/// diagnostics before publishing their bounded notification.
///
/// ```zig
/// try handler.execute(outcome);
/// ```
pub fn execute(handler: *DeliverPluginActionStartHandler, outcome: plugin_action.StartOutcome) !void {
    const failure = plugin_action_delivery.startFailurePublication(outcome) orelse return;

    try plugin_action_delivery.publishFailure(handler.model, handler.effects, failure);
}
