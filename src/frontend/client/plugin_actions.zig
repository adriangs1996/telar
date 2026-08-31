//! Adapts plugin invocation and worker completion to client application state.

const std = @import("std");
const config = @import("../config/root.zig");
const input = @import("../input/root.zig");
const plugin_broker = @import("../plugins/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const notifications = @import("../notifications/root.zig");

const Client = @import("client.zig");
const client_actions = @import("actions.zig");
const notification_flow = @import("notifications.zig");
const plugin_action = client_application.plugin_action;
const plugin_action_delivery = client_application.plugin_action_delivery;

pub const Completion = struct {
    execution_id: client_model.PluginExecutionId,
    result: anyerror!plugin_broker.WorkerResult,
};

pub const StartOutcome = plugin_action.StartOutcome;

const Job = struct {
    execution_id: client_model.PluginExecutionId,
    request: plugin_broker.WorkerRequest,
};

const StartContext = struct {
    client: *Client,
    requested: input.action.PluginAction,
    callback_context: config.CallbackContext,
    request: ?plugin_broker.WorkerRequest = null,
};

/// Resolves one configured action and schedules its work outside the input path.
///
/// ```zig
/// const outcome = try start(client, requested, callback_context);
/// ```
pub fn start(client: *Client, requested: input.action.PluginAction, callback_context: config.CallbackContext) !StartOutcome {
    var context: StartContext = .{
        .client = client,
        .requested = requested,
        .callback_context = callback_context,
    };
    var use_case: plugin_action.StartPluginActionHandler = .{
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
pub fn complete(client: *Client, completion: Completion) !bool {
    var use_case: plugin_action.CompletePluginActionHandler = .{
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
    const command: plugin_action.CompletionCommand = if (completion.result) |result|
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

fn schedule(raw_context: *anyopaque, execution: client_model.PluginExecution) !void {
    const context: *StartContext = @ptrCast(@alignCast(raw_context));
    const request = context.request orelse return error.PluginRequestMissing;

    try context.client.select.concurrent(.plugin_result, executeWorker, .{
        context.client.io,
        context.client.gpa,
        Job{ .execution_id = execution.id, .request = request },
    });
}

fn executeWorker(io: std.Io, gpa: std.mem.Allocator, job: Job) Completion {
    return .{
        .execution_id = job.execution_id,
        .result = plugin_broker.executeWorker(io, gpa, job.request),
    };
}

fn deliverStartOutcome(raw_context: *anyopaque, outcome: plugin_action.StartOutcome) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    var use_case: plugin_action_delivery.DeliverPluginActionStartHandler = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .publish_notification = publishNotification,
        },
    };

    try use_case.execute(outcome);
}

fn authorize(raw_context: *anyopaque, result: plugin_action.PluginResult) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    const registry = client.plugin_registry orelse return error.PluginRegistryUnavailable;

    try registry.authorizeBatch(
        result.package_index,
        result.plugin_id,
        result.digest,
        result.batch,
    );
}

fn applyBatch(raw_context: *anyopaque, batch: *const config.EffectBatch) !plugin_action.BatchDisposition {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    for (batch.slice()) |effect| {
        if (try client_actions.apply(client, effect) == .stop) {
            return .exit_client;
        }
    }

    return .continue_client;
}

fn deliverOutcome(raw_context: *anyopaque, outcome: plugin_action.CompletionOutcome) !plugin_action.CompletionDirective {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    var use_case: plugin_action_delivery.DeliverPluginActionCompletionHandler = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .publish_notification = publishNotification,
        },
    };

    return use_case.execute(outcome);
}

fn publishNotification(raw_context: *anyopaque, notification: notifications.Input) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try notification_flow.publishNow(client, notification);
}
