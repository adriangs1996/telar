const ModelType = @import("../../model/Model.zig");
const PluginActionCompletionEffects = @import("PluginActionCompletionEffects.zig");
const PluginActionCompletionDelivery = @import("PluginActionCompletionDelivery.zig");
const plugin_action = @import("plugin_action.zig");
const CompletionResult = @import("CompletionResult.zig");
const ClientDiagnosticHandlerType = @import("../configuration/ClientDiagnosticHandler.zig");
const CompletePluginActionHandler = @This();

model: *ModelType,
effects: PluginActionCompletionEffects,
delivery: PluginActionCompletionDelivery,

/// Consumes an exact completion before checking staleness or running effects.
///
/// ```zig
/// const result = try handler.execute(command);
/// ```
pub fn execute(handler: *CompletePluginActionHandler, command: plugin_action.CompletionCommand) !CompletionResult {
    const execution = handler.model.finishPluginExecution(command.executionId()) orelse
        return handler.deliver(.ignored);
    if (execution.configuration_generation != handler.model.configurationGeneration()) {
        return handler.deliver(.stale);
    }

    return handler.deliver(switch (command) {
        .failed => |failure| .{ .worker_failed = failure.reason },
        .succeeded => |result| result: {
            handler.effects.authorize(handler.effects.context, result) catch |err| {
                break :result .{ .authorization_failed = err };
            };

            var diagnostic_handler: ClientDiagnosticHandlerType = .{ .model = handler.model };
            _ = diagnostic_handler.clear();
            const disposition = try handler.effects.apply(handler.effects.context, result.batch);
            break :result switch (disposition) {
                .continue_client => .applied,
                .exit_client => .exit,
            };
        },
    });
}

fn deliver(handler: *CompletePluginActionHandler, outcome: plugin_action.CompletionOutcome) !CompletionResult {
    return .{
        .outcome = outcome,
        .directive = try handler.delivery.deliver(handler.delivery.context, outcome),
    };
}
