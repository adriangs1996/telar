//! Adapts plugin invocation and worker completion to client application state.

const Client = @import("../../Client.zig");
const PluginActionType = @import("telar-client").PluginAction;
const CallbackContextType = @import("telar-client").CallbackContext;
const StartOutcome = @import("telar-client").StartOutcome;
const StartContext = @import("StartContext.zig");
const StartPluginActionHandlerType = @import("telar-client").StartPluginActionHandler;
const PluginActionsCompletion = @import("PluginActionsCompletion.zig");
const CompletePluginActionHandlerType = @import("telar-client").CompletePluginActionHandler;
const CompletionCommandType = @import("telar-client").CompletionCommand;
const PluginExecutionType = @import("telar-client").PluginExecution;
const PluginActionsJob = @import("PluginActionsJob.zig");
const std = @import("std");
const plugin_broker = @import("../../../plugins/plugins.zig");
const DeliverPluginActionStartHandlerType = @import("telar-client").DeliverPluginActionStartHandler;
const PluginResultType = @import("telar-client").PluginResult;
const EffectBatchType = @import("telar-client").EffectBatch;
const BatchDispositionType = @import("telar-client").BatchDisposition;
const client_actions = @import("../input/actions.zig");
const CompletionOutcomeType = @import("telar-client").CompletionOutcome;
const CompletionDirectiveType = @import("telar-client").CompletionDirective;
const DeliverPluginActionCompletionHandlerType = @import("telar-client").DeliverPluginActionCompletionHandler;
const InputType = @import("telar-client").NotificationInput;
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
    var use_case: StartPluginActionHandlerType = .{
        .model = &client.model,
        .effects = .{
            .context = &context,
            .prepare = prepare,
            .schedule = schedule,
        },
        .delivery = .{
            .context = client,
            .deliver = deliverStartOutcome,
        },
    };

    return use_case.execute();
}

/// Consumes one worker completion and applies its authorized action batch.
///
/// ```zig
/// if (try complete(client, completion)) {
///     return;
/// }
/// ```
pub fn complete(client: *Client, completion: PluginActionsCompletion) !bool {
    var use_case: CompletePluginActionHandlerType = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .authorize = authorize,
            .apply = applyBatch,
        },
        .delivery = .{
            .context = client,
            .deliver = deliverOutcome,
        },
    };
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
    const result = try use_case.execute(command);

    return result.directive == .exit_client;
}

fn prepare(raw_context: *anyopaque) !void {
    const context: *StartContext = @ptrCast(@alignCast(raw_context));
    const registry = context.client.plugin_registry orelse
        return error.PluginRegistryUnavailable;
    const invocation = try registry.resolve(context.requested);
    context.request = try registry.workerRequest(invocation, context.callback_context);
}

fn schedule(raw_context: *anyopaque, execution: PluginExecutionType) !void {
    const context: *StartContext = @ptrCast(@alignCast(raw_context));
    const request = context.request orelse return error.PluginRequestMissing;

    try context.client.select.concurrent(.plugin_result, executeWorker, .{
        context.client.io,
        context.client.gpa,
        PluginActionsJob{ .execution_id = execution.id, .request = request },
    });
}

fn executeWorker(io: std.Io, gpa: std.mem.Allocator, job: PluginActionsJob) PluginActionsCompletion {
    return .{
        .execution_id = job.execution_id,
        .result = plugin_broker.executeWorker(io, gpa, job.request),
    };
}

fn deliverStartOutcome(raw_context: *anyopaque, outcome: StartOutcome) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    var use_case: DeliverPluginActionStartHandlerType = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .publish_notification = publishNotification,
        },
    };

    try use_case.execute(outcome);
}

fn authorize(raw_context: *anyopaque, result: PluginResultType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    const registry = client.plugin_registry orelse return error.PluginRegistryUnavailable;

    try registry.authorizeBatch(.{
        .package_index = result.package_index,
        .plugin_id = result.plugin_id,
        .digest = result.digest,
        .batch = result.batch,
    });
}

fn applyBatch(raw_context: *anyopaque, batch: *const EffectBatchType) !BatchDispositionType {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    for (batch.slice()) |effect| {
        if (try client_actions.apply(client, effect) == .stop) {
            return .exit_client;
        }
    }

    return .continue_client;
}

fn deliverOutcome(raw_context: *anyopaque, outcome: CompletionOutcomeType) !CompletionDirectiveType {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    var use_case: DeliverPluginActionCompletionHandlerType = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .publish_notification = publishNotification,
        },
    };

    return use_case.execute(outcome);
}

fn publishNotification(raw_context: *anyopaque, notification: InputType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try notification_flow.publishNow(client, notification);
}
