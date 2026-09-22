//! Adapts plugin invocation and worker completion to client application state.

const std = @import("std");
const plugin_action_delivery = @import("../../application/input/plugin_action_delivery.zig");
const client_diagnostic = @import("../../application/configuration/client_diagnostic.zig");
const FailurePublication = @import("../../application/input/FailurePublication.zig");
const Client = @import("../../AttachedClient.zig");
const PluginActionType = @import("../../input/PluginAction.zig");
const CallbackContextType = @import("../../config/CallbackContext.zig");
const StartOutcome = @import("../../application/input/plugin_action.zig").StartOutcome;
const StartContext = @import("StartContext.zig");
const PluginActionsCompletion = @import("../../plugins/PluginActionsCompletion.zig");
const CompletionCommandType = @import("../../application/input/plugin_action.zig").CompletionCommand;
const PluginExecutionType = @import("../../model/PluginExecution.zig");
const PluginResultType = @import("../../application/input/PluginResult.zig");
const EffectBatchType = @import("../../config/EffectBatch.zig");
const BatchDispositionType = @import("../../application/input/plugin_action.zig").BatchDisposition;
const CompletionOutcomeType = @import("../../application/input/plugin_action.zig").CompletionOutcome;
const notification_flow = @import("../notifications/notifications.zig");

/// Resolves one configured action and schedules its work outside the input path.
///
/// ```zig
/// const outcome = try start(client, requested, callback_context);
/// ```
pub fn start(client: *Client, requested: PluginActionType, callback_context: CallbackContextType) !StartOutcome {
    var context: StartContext = .{
        .client = client,
        .requested = requested,
        .callback_context = callback_context,
    };

    if (client.model.pluginExecution() != null) {
        return deliverStartOutcome(client, .busy);
    }

    prepare(&context) catch |err| switch (err) {
        error.PluginRegistryUnavailable => return deliverStartOutcome(client, .unavailable),
        error.PluginNotConfigured, error.UnknownPluginAction => return deliverStartOutcome(client, .{ .rejected = err }),
    };
    const execution = (try client.model.beginPluginExecution()) orelse
        return deliverStartOutcome(client, .busy);
    {
        errdefer {
            const rolled_back = client.model.finishPluginExecution(execution.id);
            std.debug.assert(rolled_back != null);
        }

        try schedule(&context, execution);
    }

    return deliverStartOutcome(client, .{ .started = execution });
}

/// Consumes one worker completion and applies its authorized action batch.
///
/// ```zig
/// if (try complete(client, completion)) {
///     return;
/// }
/// ```
pub fn complete(client: *Client, completion: PluginActionsCompletion) !bool {
    const command: CompletionCommandType = if (completion.result) |result|
        .{ .succeeded = .{
            .execution_id = completion.execution_id,
            .package_index = result.package_index,
            .plugin_id = result.plugin_id,
            .digest = result.digest,
            .batch = &result.batch,
        } }
    else |err|
        .{ .failed = .{
            .execution_id = completion.execution_id,
            .reason = err,
        } };

    const execution = client.model.finishPluginExecution(command.executionId()) orelse
        return deliverOutcome(client, .ignored);
    if (execution.configuration_generation != client.model.configurationGeneration()) {
        return deliverOutcome(client, .stale);
    }

    return deliverOutcome(client, switch (command) {
        .failed => |failure| .{ .worker_failed = failure.reason },
        .succeeded => |result| result: {
            authorize(client, result) catch |err| {
                break :result .{ .authorization_failed = err };
            };

            _ = client.model.clearDiagnostic();
            const disposition = try applyBatch(client, result.batch);
            break :result switch (disposition) {
                .continue_client => .applied,
                .exit_client => .exit,
            };
        },
    });
}

fn prepare(context: *StartContext) !void {
    const registry = context.client.plugin_registry orelse
        return error.PluginRegistryUnavailable;
    const invocation = try registry.resolve(context.requested);
    context.request = try registry.workerRequest(invocation, context.callback_context);
}

fn schedule(context: *StartContext, execution: PluginExecutionType) !void {
    const request = context.request orelse return error.PluginRequestMissing;

    try context.client.plugin_runner.start(.{ .execution_id = execution.id, .request = request });
}

fn deliverStartOutcome(client: *Client, outcome: StartOutcome) !StartOutcome {
    if (plugin_action_delivery.startFailurePublication(outcome)) |failure| {
        try publishFailure(client, failure);
    }
    return outcome;
}

fn authorize(client: *Client, result: PluginResultType) !void {
    const registry = client.plugin_registry orelse return error.PluginRegistryUnavailable;

    try registry.authorizeBatch(.{
        .package_index = result.package_index,
        .plugin_id = result.plugin_id,
        .digest = result.digest,
        .batch = result.batch,
    });
}

fn applyBatch(client: *Client, batch: *const EffectBatchType) !BatchDispositionType {
    for (batch.slice()) |effect| {
        if (try client.executeAction(effect, .effect) == .stop) {
            return .exit_client;
        }
    }

    return .continue_client;
}

fn deliverOutcome(client: *Client, outcome: CompletionOutcomeType) !bool {
    if (plugin_action_delivery.completionFailurePublication(outcome)) |failure| {
        try publishFailure(client, failure);
    }
    return outcome == .exit;
}

fn publishFailure(client: *Client, failure: FailurePublication) !void {
    _ = try client_diagnostic.replace(&client.model, .{ .diagnostic = failure.diagnostic });
    try notification_flow.publishNow(client, .{
        .level = .failure,
        .title = failure.title,
        .message = client.model.diagnostic() orelse return error.ClientDiagnosticMissing,
        .duration_ns = 7 * std.time.ns_per_s,
    });
}
