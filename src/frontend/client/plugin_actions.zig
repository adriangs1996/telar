//! Adapts plugin invocation and worker completion to client application state.

const std = @import("std");
const config = @import("../config/root.zig");
const input = @import("../input/root.zig");
const plugin_broker = @import("../plugins/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");

const Client = @import("client.zig");
const client_actions = @import("actions.zig");
const client_diagnostics = @import("client_diagnostics.zig");
const notification_flow = @import("notifications.zig");
const plugin_action = client_application.plugin_action;

pub const Completion = struct {
    execution_id: client_model.PluginExecutionId,
    result: anyerror!plugin_broker.WorkerResult,
};

pub const StartOutcome = union(enum) {
    started: client_model.PluginExecution,
    busy,
    unavailable,
    rejected,
};

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
    };
    const outcome = use_case.execute() catch |err| switch (err) {
        error.PluginRegistryUnavailable => return .unavailable,
        error.PluginNotConfigured, error.UnknownPluginAction => {
            _ = try client_diagnostics.set(
                client,
                "plugin action cannot be resolved: {s}",
                .{@errorName(err)},
            );
            try notification_flow.publishDiagnostic(client, "Plugin action rejected");
            return .rejected;
        },
        else => return err,
    };

    return switch (outcome) {
        .started => |execution| .{ .started = execution },
        .busy => .busy,
    };
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
    const outcome = try use_case.execute(command);

    return handleOutcome(client, outcome);
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
    _ = client_diagnostics.clear(client);
    for (batch.slice()) |effect| {
        if (try client_actions.apply(client, effect) == .stop) {
            return .exit_client;
        }
    }

    return .continue_client;
}

fn handleOutcome(client: *Client, outcome: plugin_action.CompletionOutcome) !bool {
    switch (outcome) {
        .applied => return false,
        .exit => return true,
        .stale, .ignored => return false,
        .worker_failed => |err| {
            _ = try client_diagnostics.set(client, "plugin worker failed: {s}", .{@errorName(err)});
            try notification_flow.publishDiagnostic(client, "Plugin failed");
            return false;
        },
        .authorization_failed => |err| {
            const title = if (err == error.PluginRegistryUnavailable) failed: {
                _ = try client_diagnostics.set(
                    client,
                    "plugin registry changed while action was running",
                    .{},
                );
                break :failed "Plugin failed";
            } else denied: {
                _ = try client_diagnostics.set(client, "plugin effect denied: {s}", .{@errorName(err)});
                break :denied "Plugin denied";
            };
            try notification_flow.publishDiagnostic(client, title);
            return false;
        },
    }
}
