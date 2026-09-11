const CompletePluginActionHandler = @This();
const client_model = @import("../../root.zig").model;
const CompletionEffects = @import("PluginActionCompletionEffects.zig");
const CompletionDelivery = @import("PluginActionCompletionDelivery.zig");
const source_namespace = @import("plugin_action.zig");
const CompletionResult = @import("CompletionResult.zig");
const client_diagnostic = @import("../configuration/root.zig").client_diagnostic;
model: *client_model.Model,
effects: CompletionEffects,
delivery: CompletionDelivery,

/// Consumes an exact completion before checking staleness or running effects.
///
/// ```zig
/// const result = try handler.execute(command);
/// ```
pub fn execute(handler: *CompletePluginActionHandler, command: source_namespace.CompletionCommand) !CompletionResult {
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

            var diagnostic_handler: client_diagnostic.ClientDiagnosticHandler = .{ .model = handler.model };
            _ = diagnostic_handler.clear();
            const disposition = try handler.effects.apply(handler.effects.context, result.batch);
            break :result switch (disposition) {
                .continue_client => .applied,
                .exit_client => .exit,
            };
        },
    });
}

fn deliver(handler: *CompletePluginActionHandler, outcome: source_namespace.CompletionOutcome) !CompletionResult {
    return .{
        .outcome = outcome,
        .directive = try handler.delivery.deliver(handler.delivery.context, outcome),
    };
}
