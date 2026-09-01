//! Application policy for one bounded local clipboard image capture.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../../agents/root.zig");
const attachments = @import("../../../attachments/root.zig");
const client_model = @import("../../model.zig");

const schema = core.schema;

pub const StartEffects = struct {
    context: *anyopaque,
    schedule: *const fn (*anyopaque, client_model.ClipboardCapture) anyerror!void,
};

pub const StartOutcome = union(enum) {
    started: client_model.ClipboardCapture,
    busy,
    unsupported,
    no_target,
};

pub const StartClipboardImageHandler = struct {
    model: *client_model.Model,
    effects: StartEffects,

    /// Resolves one supported focused target and commits its capture identity
    /// before scheduling the media worker.
    ///
    /// ```zig
    /// const outcome = try handler.execute(platform_supported);
    /// ```
    pub fn execute(handler: *StartClipboardImageHandler, platform_supported: bool) !StartOutcome {
        if (!platform_supported) {
            return .unsupported;
        }

        const target = handler.model.focusedAttachmentTarget() orelse return .no_target;
        const capture = (try handler.model.beginClipboardCapture(target)) orelse return .busy;
        errdefer {
            const rolled_back = handler.model.finishClipboardCapture(capture.id);
            std.debug.assert(rolled_back != null);
        }

        try handler.effects.schedule(handler.effects.context, capture);
        return .{ .started = capture };
    }
};

pub const CapturedImage = struct {
    execution_id: client_model.ClipboardCaptureId,
    result_id: client_model.ClipboardCaptureId,
    target: attachments.Target,
};

pub const CompletionCommand = union(enum) {
    succeeded: CapturedImage,
    failed: struct {
        execution_id: client_model.ClipboardCaptureId,
        reason: anyerror,
    },

    fn executionId(command: CompletionCommand) client_model.ClipboardCaptureId {
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

pub const CompletionDelivery = struct {
    context: *anyopaque,
    deliver: *const fn (*anyopaque, CompletionOutcome) anyerror!void,
};

pub const CompletionEffects = struct {
    context: *anyopaque,
    adopt: *const fn (*anyopaque) anyerror!bool,
    resize: *const fn (*anyopaque) anyerror!void,
};

pub const CompleteClipboardImageHandler = struct {
    model: *client_model.Model,
    effects: CompletionEffects,
    delivery: CompletionDelivery,

    /// Consumes one exact completion before validating or applying its image.
    ///
    /// ```zig
    /// const outcome = try handler.execute(command);
    /// ```
    pub fn execute(handler: *CompleteClipboardImageHandler, command: CompletionCommand) !CompletionOutcome {
        const capture = handler.model.finishClipboardCapture(command.executionId()) orelse
            return handler.deliver(.ignored);

        return handler.deliver(switch (command) {
            .failed => |failure| classifyFailure(failure.reason),
            .succeeded => |result| result: {
                if (result.result_id != capture.id or !std.meta.eql(result.target, capture.target)) {
                    break :result .stale;
                }

                const current = handler.model.focusedAttachmentTarget() orelse
                    break :result .stale;
                if (!std.meta.eql(current, capture.target)) {
                    break :result .stale;
                }

                const layout_changed = handler.effects.adopt(handler.effects.context) catch |err| {
                    break :result .{ .adoption_failed = err };
                };
                if (layout_changed) {
                    try handler.effects.resize(handler.effects.context);
                }

                break :result .applied;
            },
        });
    }

    fn deliver(handler: *CompleteClipboardImageHandler, outcome: CompletionOutcome) !CompletionOutcome {
        try handler.delivery.deliver(handler.delivery.context, outcome);

        return outcome;
    }
};

fn classifyFailure(reason: anyerror) CompletionOutcome {
    return switch (reason) {
        error.NoImageOnClipboard => .no_image,
        error.ClipboardImageTooLarge => .too_large,
        else => .{ .worker_failed = reason },
    };
}

const StartCapture = struct {
    model: *const client_model.Model,
    calls: usize = 0,
    observed_commit: bool = false,
    fail: bool = false,

    fn port(capture: *StartCapture) StartEffects {
        return .{ .context = capture, .schedule = schedule };
    }

    fn schedule(raw_context: *anyopaque, expected: client_model.ClipboardCapture) !void {
        const capture: *StartCapture = @ptrCast(@alignCast(raw_context));
        capture.calls += 1;
        capture.observed_commit = std.meta.eql(capture.model.clipboardCapture().?, expected);
        if (capture.fail) {
            return error.CaptureScheduleFailed;
        }
    }
};

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

const CompletionEvent = enum {
    adopt,
    resize,
};

const CompletionCapture = struct {
    model: *const client_model.Model,
    events: [2]CompletionEvent = undefined,
    event_count: usize = 0,
    observed_finished: bool = false,
    layout_changed: bool = false,
    fail_adopt: bool = false,
    fail_resize: bool = false,

    fn port(capture: *CompletionCapture) CompletionEffects {
        return .{
            .context = capture,
            .adopt = adopt,
            .resize = resize,
        };
    }

    fn adopt(raw_context: *anyopaque) !bool {
        const capture: *CompletionCapture = @ptrCast(@alignCast(raw_context));
        capture.events[capture.event_count] = .adopt;
        capture.event_count += 1;
        capture.observed_finished = capture.model.clipboardCapture() == null;
        if (capture.fail_adopt) {
            return error.AttachmentAdoptionFailed;
        }

        return capture.layout_changed;
    }

    fn resize(raw_context: *anyopaque) !void {
        const capture: *CompletionCapture = @ptrCast(@alignCast(raw_context));
        capture.events[capture.event_count] = .resize;
        capture.event_count += 1;
        capture.observed_finished = capture.observed_finished and
            capture.model.clipboardCapture() == null;
        if (capture.fail_resize) {
            return error.AttachmentResizeFailed;
        }
    }
};

const CompletionDeliveryCapture = struct {
    calls: usize = 0,
    outcome: ?CompletionOutcome = null,
    fail: bool = false,

    fn port(capture: *CompletionDeliveryCapture) CompletionDelivery {
        return .{ .context = capture, .deliver = deliver };
    }

    fn deliver(raw_context: *anyopaque, outcome: CompletionOutcome) !void {
        const capture: *CompletionDeliveryCapture = @ptrCast(@alignCast(raw_context));
        capture.calls += 1;
        capture.outcome = outcome;

        if (capture.fail) {
            return error.CompletionDeliveryFailed;
        }
    }
};

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
    try model.workspace.bootstrap(target.pane_id, location, .{ .cols = 20, .rows = 5 });
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
