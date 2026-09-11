//! Application policy for one bounded local clipboard image capture.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../root.zig").agents;
const attachments = @import("../../attachments/root.zig");
const client_model = @import("../../root.zig").model;

const schema = core.schema;

pub const StartEffects = @import("ClipboardImageStartEffects.zig");

pub const StartOutcome = union(enum) {
    started: client_model.ClipboardCapture,
    busy,
    unsupported,
    no_target,
};

pub const StartClipboardImageHandler = @import("StartClipboardImageHandler.zig");

pub const CapturedImage = @import("CapturedImage.zig");

pub const CompletionCommand = union(enum) {
    succeeded: CapturedImage,
    failed: struct {
        execution_id: client_model.ClipboardCaptureId,
        reason: anyerror,
    },

    pub fn executionId(command: CompletionCommand) client_model.ClipboardCaptureId {
        return switch (command) {
            .succeeded => |result| result.execution_id,
            .failed => |failure| failure.execution_id,
        };
    }
};

pub const CompletionOutcome = union(enum) {
    applied,
    stale,
    ignored,
    no_image,
    too_large,
    worker_failed: anyerror,
    adoption_failed: anyerror,
};

pub const CompletionDelivery = @import("ClipboardImageCompletionDelivery.zig");

pub const CompletionEffects = @import("ClipboardImageCompletionEffects.zig");

pub const CompleteClipboardImageHandler = @import("CompleteClipboardImageHandler.zig");

pub fn classifyFailure(reason: anyerror) CompletionOutcome {
    return switch (reason) {
        error.NoImageOnClipboard => .no_image,
        error.ClipboardImageTooLarge => .too_large,
        else => .{ .worker_failed = reason },
    };
}

const StartCapture = @import("ClipboardImageStartCapture.zig");

test "StartClipboardImageHandler commits before scheduling and suppresses a second capture" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const target = try installFocusedTarget(&model);
    var capture: StartCapture = .{ .model = &model };
    var handler: StartClipboardImageHandler = .{
        .model = &model,
        .effects = capture.port(),
    };

    const started = try handler.execute(true);
    const busy = try handler.execute(true);

    try std.testing.expect(started == .started);
    try std.testing.expectEqualDeep(target, started.started.target);
    try std.testing.expect(busy == .busy);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "StartClipboardImageHandler owns unsupported and missing target outcomes" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: StartCapture = .{ .model = &model };
    var handler: StartClipboardImageHandler = .{
        .model = &model,
        .effects = capture.port(),
    };

    try std.testing.expect(try handler.execute(true) == .no_target);

    _ = try installFocusedTarget(&model);

    try std.testing.expect(try handler.execute(false) == .unsupported);
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expect(model.clipboardCapture() == null);
}

test "StartClipboardImageHandler rolls back the exact reservation after scheduling failure" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    _ = try installFocusedTarget(&model);
    var capture: StartCapture = .{ .model = &model, .fail = true };
    var handler: StartClipboardImageHandler = .{
        .model = &model,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.CaptureScheduleFailed, handler.execute(true));
    try std.testing.expect(model.clipboardCapture() == null);
}

pub const CompletionEvent = enum {
    adopt,
    resize,
};

const CompletionCapture = @import("ClipboardImageCompletionCapture.zig");

const CompletionDeliveryCapture = @import("ClipboardImageCompletionDeliveryCapture.zig");

fn completionHandler(model: *client_model.Model, capture: *CompletionCapture, delivery: *CompletionDeliveryCapture) CompleteClipboardImageHandler {
    return .{
        .model = model,
        .effects = capture.port(),
        .delivery = delivery.port(),
    };
}

fn installFocusedTarget(model: *client_model.Model) !attachments.Target {
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const target: attachments.Target = .{
        .pane_id = @enumFromInt(7),
        .pane_generation = 2,
    };
    try model.workspace.bootstrap(.{ .pane_id = target.pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model.reconcileAgentSnapshot(.{
        .revision = 1,
        .agents = &.{agents.AgentInput{
            .key = .{
                .pane_id = target.pane_id,
                .pane_generation = target.pane_generation,
            },
            .location = location,
            .pane_index = 1,
            .provider = .codex,
            .attachments = .ordered,
            .status = .working,
        }},
    });
    return target;
}

fn successfulCommand(capture: client_model.ClipboardCapture) CompletionCommand {
    return .{ .succeeded = .{
        .execution_id = capture.id,
        .result_id = capture.id,
        .target = capture.target,
    } };
}

test "CompleteClipboardImageHandler adopts before resize after consuming the run" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const target = try installFocusedTarget(&model);
    const execution = (try model.beginClipboardCapture(target)).?;
    var capture: CompletionCapture = .{
        .model = &model,
        .layout_changed = true,
    };
    var delivery: CompletionDeliveryCapture = .{};
    var handler = completionHandler(&model, &capture, &delivery);

    const outcome = try handler.execute(successfulCommand(execution));

    try std.testing.expect(outcome == .applied);
    try std.testing.expect(capture.observed_finished);
    try std.testing.expectEqual(@as(usize, 1), delivery.calls);
    try std.testing.expect(delivery.outcome.? == .applied);
    try std.testing.expectEqualSlices(
        CompletionEvent,
        &.{ .adopt, .resize },
        capture.events[0..capture.event_count],
    );
}

test "CompleteClipboardImageHandler preserves unmatched work and drops stale results" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const target = try installFocusedTarget(&model);
    const execution = (try model.beginClipboardCapture(target)).?;
    var capture: CompletionCapture = .{ .model = &model };
    var delivery: CompletionDeliveryCapture = .{};
    var handler = completionHandler(&model, &capture, &delivery);

    const ignored = try handler.execute(.{ .failed = .{
        .execution_id = @enumFromInt(99),
        .reason = error.ClipboardReadFailed,
    } });

    try std.testing.expect(ignored == .ignored);
    try std.testing.expectEqualDeep(execution, model.clipboardCapture().?);
    try std.testing.expectEqual(@as(usize, 1), delivery.calls);
    try std.testing.expect(delivery.outcome.? == .ignored);

    var stale_command = successfulCommand(execution);
    stale_command.succeeded.result_id = @enumFromInt(98);
    const stale = try handler.execute(stale_command);

    try std.testing.expect(stale == .stale);
    try std.testing.expect(model.clipboardCapture() == null);
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
    try std.testing.expectEqual(@as(usize, 2), delivery.calls);
    try std.testing.expect(delivery.outcome.? == .stale);
}

test "CompleteClipboardImageHandler classifies worker and adoption failures" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const target = try installFocusedTarget(&model);
    var capture: CompletionCapture = .{ .model = &model };
    var delivery: CompletionDeliveryCapture = .{};
    var handler = completionHandler(&model, &capture, &delivery);

    const no_image = (try model.beginClipboardCapture(target)).?;
    try std.testing.expect((try handler.execute(.{ .failed = .{
        .execution_id = no_image.id,
        .reason = error.NoImageOnClipboard,
    } })) == .no_image);

    const too_large = (try model.beginClipboardCapture(target)).?;
    try std.testing.expect((try handler.execute(.{ .failed = .{
        .execution_id = too_large.id,
        .reason = error.ClipboardImageTooLarge,
    } })) == .too_large);

    const worker_failed = (try model.beginClipboardCapture(target)).?;
    const failed = try handler.execute(.{ .failed = .{
        .execution_id = worker_failed.id,
        .reason = error.ClipboardReadFailed,
    } });
    try std.testing.expectEqual(error.ClipboardReadFailed, failed.worker_failed);

    capture.fail_adopt = true;
    const adoption_failed = (try model.beginClipboardCapture(target)).?;
    const rejected = try handler.execute(successfulCommand(adoption_failed));

    try std.testing.expectEqual(error.AttachmentAdoptionFailed, rejected.adoption_failed);
    try std.testing.expectEqual(@as(usize, 1), capture.event_count);
    try std.testing.expectEqual(@as(usize, 4), delivery.calls);
    try std.testing.expectEqual(error.AttachmentAdoptionFailed, delivery.outcome.?.adoption_failed);
    try std.testing.expect(model.clipboardCapture() == null);
}

test "CompleteClipboardImageHandler propagates resize failure after adoption" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const target = try installFocusedTarget(&model);
    const execution = (try model.beginClipboardCapture(target)).?;
    var capture: CompletionCapture = .{
        .model = &model,
        .layout_changed = true,
        .fail_resize = true,
    };
    var delivery: CompletionDeliveryCapture = .{};
    var handler = completionHandler(&model, &capture, &delivery);

    try std.testing.expectError(
        error.AttachmentResizeFailed,
        handler.execute(successfulCommand(execution)),
    );
    try std.testing.expectEqualSlices(
        CompletionEvent,
        &.{ .adopt, .resize },
        capture.events[0..capture.event_count],
    );
    try std.testing.expect(model.clipboardCapture() == null);
    try std.testing.expectEqual(@as(usize, 0), delivery.calls);
}

test "CompleteClipboardImageHandler preserves completion after delivery failure" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const target = try installFocusedTarget(&model);
    const execution = (try model.beginClipboardCapture(target)).?;
    var capture: CompletionCapture = .{ .model = &model };
    var delivery: CompletionDeliveryCapture = .{ .fail = true };
    var handler = completionHandler(&model, &capture, &delivery);

    try std.testing.expectError(error.CompletionDeliveryFailed, handler.execute(.{ .failed = .{
        .execution_id = execution.id,
        .reason = error.NoImageOnClipboard,
    } }));

    try std.testing.expect(model.clipboardCapture() == null);
    try std.testing.expectEqual(@as(usize, 1), delivery.calls);
    try std.testing.expect(delivery.outcome.? == .no_image);
}
