//! Application policy for one bounded client plugin execution.

const std = @import("std");
const core = @import("telar-core");
const config = @import("../../../config/root.zig");
const client_diagnostic = @import("../configuration/client_diagnostic.zig");
const client_model = @import("../../model.zig");

const plugin = core.plugin;

pub const StartEffects = struct {
    context: *anyopaque,
    prepare: *const fn (*anyopaque) anyerror!void,
    schedule: *const fn (*anyopaque, client_model.PluginExecution) anyerror!void,
};

pub const StartOutcome = union(enum) {
    started: client_model.PluginExecution,
    busy,
    unavailable,
    rejected: anyerror,
};

pub const StartDelivery = struct {
    context: *anyopaque,
    deliver: *const fn (*anyopaque, StartOutcome) anyerror!void,
};

pub const StartPluginActionHandler = struct {
    model: *client_model.Model,
    effects: StartEffects,
    delivery: StartDelivery,

    /// Prepares one invocation, starts its worker under one committed identity,
    /// then delivers the classified start outcome.
    ///
    /// ```zig
    /// const outcome = try handler.execute();
    /// ```
    pub fn execute(handler: *StartPluginActionHandler) !StartOutcome {
        if (handler.model.pluginExecution() != null) {
            return handler.deliver(.busy);
        }

        handler.effects.prepare(handler.effects.context) catch |err| switch (err) {
            error.PluginRegistryUnavailable => return handler.deliver(.unavailable),
            error.PluginNotConfigured, error.UnknownPluginAction => return handler.deliver(.{ .rejected = err }),
            else => return err,
        };
        const execution = (try handler.model.beginPluginExecution()) orelse
            return handler.deliver(.busy);
        {
            errdefer {
                const rolled_back = handler.model.finishPluginExecution(execution.id);
                std.debug.assert(rolled_back != null);
            }

            try handler.effects.schedule(handler.effects.context, execution);
        }

        return handler.deliver(.{ .started = execution });
    }

    fn deliver(handler: *StartPluginActionHandler, outcome: StartOutcome) !StartOutcome {
        try handler.delivery.deliver(handler.delivery.context, outcome);

        return outcome;
    }
};

pub const PluginResult = struct {
    execution_id: client_model.PluginExecutionId,
    package_index: u8,
    plugin_id: u64,
    digest: plugin.Digest,
    /// Borrowed only while the completion handler executes synchronously.
    batch: *const config.EffectBatch,
};

pub const CompletionCommand = union(enum) {
    succeeded: PluginResult,
    failed: struct {
        execution_id: client_model.PluginExecutionId,
        reason: anyerror,
    },

    fn executionId(command: CompletionCommand) client_model.PluginExecutionId {
        return switch (command) {
            .succeeded => |result| result.execution_id,
            .failed => |failure| failure.execution_id,
        };
    }
};

pub const BatchDisposition = enum {
    continue_client,
    exit_client,
};

pub const CompletionOutcome = union(enum) {
    applied,
    exit,
    stale,
    ignored,
    worker_failed: anyerror,
    authorization_failed: anyerror,
};

pub const CompletionDirective = enum {
    continue_client,
    exit_client,
};

pub const CompletionResult = struct {
    outcome: CompletionOutcome,
    directive: CompletionDirective,
};

pub const CompletionDelivery = struct {
    context: *anyopaque,
    deliver: *const fn (*anyopaque, CompletionOutcome) anyerror!CompletionDirective,
};

pub const CompletionEffects = struct {
    context: *anyopaque,
    authorize: *const fn (*anyopaque, PluginResult) anyerror!void,
    apply: *const fn (*anyopaque, *const config.EffectBatch) anyerror!BatchDisposition,
};

pub const CompletePluginActionHandler = struct {
    model: *client_model.Model,
    effects: CompletionEffects,
    delivery: CompletionDelivery,

    /// Consumes an exact completion before checking staleness or running effects.
    ///
    /// ```zig
    /// const result = try handler.execute(command);
    /// ```
    pub fn execute(handler: *CompletePluginActionHandler, command: CompletionCommand) !CompletionResult {
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

    fn deliver(handler: *CompletePluginActionHandler, outcome: CompletionOutcome) !CompletionResult {
        return .{
            .outcome = outcome,
            .directive = try handler.delivery.deliver(handler.delivery.context, outcome),
        };
    }
};

const StartCapture = struct {
    model: *const client_model.Model,
    prepare_calls: usize = 0,
    schedule_calls: usize = 0,
    delivery_calls: usize = 0,
    prepared_before_commit: bool = false,
    scheduled_after_commit: bool = false,
    prepare_error: ?anyerror = null,
    fail_schedule: bool = false,
    fail_delivery: bool = false,
    delivered_outcome: ?StartOutcome = null,

    fn port(capture: *StartCapture) StartEffects {
        return .{
            .context = capture,
            .prepare = prepare,
            .schedule = schedule,
        };
    }

    fn delivery(capture: *StartCapture) StartDelivery {
        return .{ .context = capture, .deliver = deliver };
    }

    fn prepare(raw_context: *anyopaque) !void {
        const capture: *StartCapture = @ptrCast(@alignCast(raw_context));
        capture.prepare_calls += 1;
        capture.prepared_before_commit = capture.model.pluginExecution() == null;
        if (capture.prepare_error) |err| {
            return err;
        }
    }

    fn schedule(raw_context: *anyopaque, execution: client_model.PluginExecution) !void {
        const capture: *StartCapture = @ptrCast(@alignCast(raw_context));
        capture.schedule_calls += 1;
        capture.scheduled_after_commit = std.meta.eql(
            capture.model.pluginExecution().?,
            execution,
        );
        if (capture.fail_schedule) {
            return error.PluginScheduleFailed;
        }
    }

    fn deliver(raw_context: *anyopaque, outcome: StartOutcome) !void {
        const capture: *StartCapture = @ptrCast(@alignCast(raw_context));
        capture.delivery_calls += 1;
        capture.delivered_outcome = outcome;

        if (capture.fail_delivery) {
            return error.PluginStartDeliveryFailed;
        }
    }
};

test "StartPluginActionHandler prepares before commit and schedules after commit" {
    var model = client_model.Model.initWithConfiguration(std.testing.allocator, true, 4);
    defer model.deinit();
    var capture: StartCapture = .{ .model = &model };
    var handler: StartPluginActionHandler = .{
        .model = &model,
        .effects = capture.port(),
        .delivery = capture.delivery(),
    };

    const started = try handler.execute();
    const execution = started.started;

    try std.testing.expect(capture.prepared_before_commit);
    try std.testing.expect(capture.scheduled_after_commit);
    try std.testing.expectEqual(@as(usize, 1), capture.prepare_calls);
    try std.testing.expectEqual(@as(usize, 1), capture.schedule_calls);
    try std.testing.expectEqual(@as(usize, 1), capture.delivery_calls);
    try std.testing.expectEqual(@as(u64, 4), execution.configuration_generation);

    const busy = try handler.execute();

    try std.testing.expect(busy == .busy);
    try std.testing.expectEqual(@as(usize, 1), capture.prepare_calls);
    try std.testing.expectEqual(@as(usize, 1), capture.schedule_calls);
    try std.testing.expectEqual(@as(usize, 2), capture.delivery_calls);
    try std.testing.expect(capture.delivered_outcome.? == .busy);
}

test "StartPluginActionHandler rolls back only an unscheduled reservation" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: StartCapture = .{
        .model = &model,
        .prepare_error = error.PluginPreparationFailed,
    };
    var handler: StartPluginActionHandler = .{
        .model = &model,
        .effects = capture.port(),
        .delivery = capture.delivery(),
    };

    try std.testing.expectError(error.PluginPreparationFailed, handler.execute());
    try std.testing.expect(model.pluginExecution() == null);
    try std.testing.expectEqual(@as(usize, 0), capture.schedule_calls);
    try std.testing.expectEqual(@as(usize, 0), capture.delivery_calls);

    capture.prepare_error = null;
    capture.fail_schedule = true;
    try std.testing.expectError(error.PluginScheduleFailed, handler.execute());
    try std.testing.expect(model.pluginExecution() == null);
    try std.testing.expectEqual(@as(usize, 0), capture.delivery_calls);

    capture.fail_schedule = false;
    capture.fail_delivery = true;
    try std.testing.expectError(error.PluginStartDeliveryFailed, handler.execute());
    try std.testing.expect(model.pluginExecution() != null);
    try std.testing.expectEqual(@as(usize, 1), capture.delivery_calls);
}

test "StartPluginActionHandler classifies known preparation failures before reservation" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: StartCapture = .{
        .model = &model,
        .prepare_error = error.PluginRegistryUnavailable,
    };
    var handler: StartPluginActionHandler = .{
        .model = &model,
        .effects = capture.port(),
        .delivery = capture.delivery(),
    };

    try std.testing.expect(try handler.execute() == .unavailable);

    capture.prepare_error = error.PluginNotConfigured;
    const not_configured = try handler.execute();

    try std.testing.expectEqual(error.PluginNotConfigured, not_configured.rejected);

    capture.prepare_error = error.UnknownPluginAction;
    const unknown_action = try handler.execute();

    try std.testing.expectEqual(error.UnknownPluginAction, unknown_action.rejected);
    try std.testing.expectEqual(@as(usize, 3), capture.prepare_calls);
    try std.testing.expectEqual(@as(usize, 0), capture.schedule_calls);
    try std.testing.expectEqual(@as(usize, 3), capture.delivery_calls);
    try std.testing.expectEqual(error.UnknownPluginAction, capture.delivered_outcome.?.rejected);
    try std.testing.expect(model.pluginExecution() == null);
}

const CompletionEvent = enum {
    authorize,
    apply,
};

const CompletionCapture = struct {
    model: *const client_model.Model,
    events: [2]CompletionEvent = undefined,
    event_count: usize = 0,
    observed_finished: bool = false,
    fail_authorize: bool = false,
    fail_apply: bool = false,
    disposition: BatchDisposition = .continue_client,

    fn port(capture: *CompletionCapture) CompletionEffects {
        return .{
            .context = capture,
            .authorize = authorize,
            .apply = apply,
        };
    }

    fn authorize(raw_context: *anyopaque, result: PluginResult) !void {
        const capture: *CompletionCapture = @ptrCast(@alignCast(raw_context));
        _ = result;
        capture.events[capture.event_count] = .authorize;
        capture.event_count += 1;
        capture.observed_finished = capture.model.pluginExecution() == null;
        if (capture.fail_authorize) {
            return error.PluginAuthorizationFailed;
        }
    }

    fn apply(raw_context: *anyopaque, batch: *const config.EffectBatch) !BatchDisposition {
        const capture: *CompletionCapture = @ptrCast(@alignCast(raw_context));
        _ = batch;
        capture.events[capture.event_count] = .apply;
        capture.event_count += 1;
        capture.observed_finished = capture.observed_finished and
            capture.model.pluginExecution() == null;
        if (capture.fail_apply) {
            return error.PluginEffectsFailed;
        }

        return capture.disposition;
    }
};

const CompletionDeliveryCapture = struct {
    calls: usize = 0,
    outcome: ?CompletionOutcome = null,
    fail: bool = false,

    fn port(capture: *CompletionDeliveryCapture) CompletionDelivery {
        return .{ .context = capture, .deliver = deliver };
    }

    fn deliver(raw_context: *anyopaque, outcome: CompletionOutcome) !CompletionDirective {
        const capture: *CompletionDeliveryCapture = @ptrCast(@alignCast(raw_context));
        capture.calls += 1;
        capture.outcome = outcome;

        if (capture.fail) {
            return error.PluginCompletionDeliveryFailed;
        }

        return switch (outcome) {
            .exit => .exit_client,
            else => .continue_client,
        };
    }
};

fn completionHandler(model: *client_model.Model, capture: *CompletionCapture, delivery: *CompletionDeliveryCapture) CompletePluginActionHandler {
    return .{
        .model = model,
        .effects = capture.port(),
        .delivery = delivery.port(),
    };
}

fn successfulCommand(execution_id: client_model.PluginExecutionId, batch: *const config.EffectBatch) CompletionCommand {
    return .{ .succeeded = .{
        .execution_id = execution_id,
        .package_index = 0,
        .plugin_id = 9,
        .digest = @splat(7),
        .batch = batch,
    } };
}

test "CompletePluginActionHandler consumes one result before authorization and effects" {
    var model = client_model.Model.initWithConfiguration(std.testing.allocator, true, 2);
    defer model.deinit();
    const execution = (try model.beginPluginExecution()).?;
    var batch: config.EffectBatch = .{};
    var capture: CompletionCapture = .{ .model = &model };
    var delivery: CompletionDeliveryCapture = .{};
    var handler = completionHandler(&model, &capture, &delivery);

    const result = try handler.execute(successfulCommand(execution.id, &batch));

    try std.testing.expect(result.outcome == .applied);
    try std.testing.expect(result.directive == .continue_client);
    try std.testing.expect(capture.observed_finished);
    try std.testing.expectEqual(@as(usize, 1), delivery.calls);
    try std.testing.expectEqualSlices(
        CompletionEvent,
        &.{ .authorize, .apply },
        capture.events[0..capture.event_count],
    );
    try std.testing.expect(model.pluginExecution() == null);
}

test "CompletePluginActionHandler classifies stale failed and unmatched completions" {
    var model = client_model.Model.initWithConfiguration(std.testing.allocator, true, 2);
    defer model.deinit();
    var capture: CompletionCapture = .{ .model = &model };
    var delivery: CompletionDeliveryCapture = .{};
    var handler = completionHandler(&model, &capture, &delivery);
    const execution = (try model.beginPluginExecution()).?;

    const ignored = try handler.execute(.{ .failed = .{
        .execution_id = @enumFromInt(99),
        .reason = error.PluginWorkerFailed,
    } });

    try std.testing.expect(ignored.outcome == .ignored);
    try std.testing.expectEqualDeep(execution, model.pluginExecution().?);

    _ = try model.applyConfiguration(.{
        .generation = 3,
        .sidebar_visible = true,
        .pane_gaps = true,
    });
    const stale = try handler.execute(.{ .failed = .{
        .execution_id = execution.id,
        .reason = error.PluginWorkerFailed,
    } });

    try std.testing.expect(stale.outcome == .stale);
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);

    const current = (try model.beginPluginExecution()).?;
    const failed = try handler.execute(.{ .failed = .{
        .execution_id = current.id,
        .reason = error.PluginWorkerFailed,
    } });

    try std.testing.expectEqual(error.PluginWorkerFailed, failed.outcome.worker_failed);
    try std.testing.expectEqual(@as(usize, 3), delivery.calls);
    try std.testing.expect(model.pluginExecution() == null);
}

test "CompletePluginActionHandler distinguishes authorization from effect failure" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var batch: config.EffectBatch = .{};
    var capture: CompletionCapture = .{
        .model = &model,
        .fail_authorize = true,
    };
    var delivery: CompletionDeliveryCapture = .{};
    var handler = completionHandler(&model, &capture, &delivery);
    const denied_execution = (try model.beginPluginExecution()).?;

    const denied = try handler.execute(successfulCommand(denied_execution.id, &batch));

    try std.testing.expectEqual(error.PluginAuthorizationFailed, denied.outcome.authorization_failed);
    try std.testing.expectEqual(@as(usize, 1), capture.event_count);

    capture.fail_authorize = false;
    capture.fail_apply = true;
    capture.event_count = 0;
    const failed_execution = (try model.beginPluginExecution()).?;
    try std.testing.expectError(
        error.PluginEffectsFailed,
        handler.execute(successfulCommand(failed_execution.id, &batch)),
    );
    try std.testing.expect(model.pluginExecution() == null);
    try std.testing.expectEqual(@as(usize, 2), capture.event_count);
}

test "CompletePluginActionHandler delegates exit and preserves completion after delivery failure" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var batch: config.EffectBatch = .{};
    var capture: CompletionCapture = .{
        .model = &model,
        .disposition = .exit_client,
    };
    var delivery: CompletionDeliveryCapture = .{};
    var handler = completionHandler(&model, &capture, &delivery);
    const exiting = (try model.beginPluginExecution()).?;

    const result = try handler.execute(successfulCommand(exiting.id, &batch));

    try std.testing.expect(result.outcome == .exit);
    try std.testing.expect(result.directive == .exit_client);

    delivery.fail = true;
    const failed = (try model.beginPluginExecution()).?;
    try std.testing.expectError(error.PluginCompletionDeliveryFailed, handler.execute(.{ .failed = .{
        .execution_id = failed.id,
        .reason = error.PluginWorkerFailed,
    } }));

    try std.testing.expect(model.pluginExecution() == null);
    try std.testing.expectEqual(error.PluginWorkerFailed, delivery.outcome.?.worker_failed);
}
