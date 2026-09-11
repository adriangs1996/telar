//! Application policy for one bounded client plugin execution.

const PluginExecutionType = @import("../../model/PluginExecution.zig");
const PluginResult = @import("PluginResult.zig");
const types = @import("../../model/types.zig");
const ModelType = @import("../../model/Model.zig");
const std = @import("std");
const PluginActionStartCapture = @import("PluginActionStartCapture.zig");
const StartPluginActionHandler = @import("StartPluginActionHandler.zig");
const PluginActionCompletionCapture = @import("PluginActionCompletionCapture.zig");
const PluginActionCompletionDeliveryCapture = @import("PluginActionCompletionDeliveryCapture.zig");
const CompletePluginActionHandler = @import("CompletePluginActionHandler.zig");
const EffectBatchType = @import("../../config/EffectBatch.zig");

pub const StartOutcome = union(enum) {
    started: PluginExecutionType,
    busy,
    unavailable,
    rejected: anyerror,
};

pub const CompletionCommand = union(enum) {
    succeeded: PluginResult,
    failed: struct {
        execution_id: types.PluginExecutionId,
        reason: anyerror,
    },

    pub fn executionId(command: CompletionCommand) types.PluginExecutionId {
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

test "StartPluginActionHandler prepares before commit and schedules after commit" {
    var model = ModelType.initWithConfiguration(std.testing.allocator, true, 4);
    defer model.deinit();
    var capture: PluginActionStartCapture = .{ .model = &model };
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
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: PluginActionStartCapture = .{
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
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: PluginActionStartCapture = .{
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

pub const CompletionEvent = enum {
    authorize,
    apply,
};

fn completionHandler(model: *ModelType, capture: *PluginActionCompletionCapture, delivery: *PluginActionCompletionDeliveryCapture) CompletePluginActionHandler {
    return .{
        .model = model,
        .effects = capture.port(),
        .delivery = delivery.port(),
    };
}

fn successfulCommand(execution_id: types.PluginExecutionId, batch: *const EffectBatchType) CompletionCommand {
    return .{ .succeeded = .{
        .execution_id = execution_id,
        .package_index = 0,
        .plugin_id = 9,
        .digest = @splat(7),
        .batch = batch,
    } };
}

test "CompletePluginActionHandler consumes one result before authorization and effects" {
    var model = ModelType.initWithConfiguration(std.testing.allocator, true, 2);
    defer model.deinit();
    const execution = (try model.beginPluginExecution()).?;
    var batch: EffectBatchType = .{};
    var capture: PluginActionCompletionCapture = .{ .model = &model };
    var delivery: PluginActionCompletionDeliveryCapture = .{};
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
    var model = ModelType.initWithConfiguration(std.testing.allocator, true, 2);
    defer model.deinit();
    var capture: PluginActionCompletionCapture = .{ .model = &model };
    var delivery: PluginActionCompletionDeliveryCapture = .{};
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
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var batch: EffectBatchType = .{};
    var capture: PluginActionCompletionCapture = .{
        .model = &model,
        .fail_authorize = true,
    };
    var delivery: PluginActionCompletionDeliveryCapture = .{};
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
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var batch: EffectBatchType = .{};
    var capture: PluginActionCompletionCapture = .{
        .model = &model,
        .disposition = .exit_client,
    };
    var delivery: PluginActionCompletionDeliveryCapture = .{};
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
