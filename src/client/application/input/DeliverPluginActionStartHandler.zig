const DeliverPluginActionStartHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("PluginActionDeliveryEffects.zig");
const plugin_action = @import("plugin_action.zig");
const source_namespace = @import("plugin_action_delivery.zig");
model: *client_model.Model,
effects: Effects,

/// Keeps quiet start outcomes silent and commits rejected-action
/// diagnostics before publishing their bounded notification.
///
/// ```zig
/// try handler.execute(outcome);
/// ```
pub fn execute(handler: *DeliverPluginActionStartHandler, outcome: plugin_action.StartOutcome) !void {
    const failure = source_namespace.startFailurePublication(outcome) orelse return;

    try source_namespace.publishFailure(handler.model, handler.effects, failure);
}
