//! Vertical and application tests for the runtime pane-input flow.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../agent/root.zig");
const pane_mod = @import("../../pane/root.zig");
const attachment_mod = @import("../attachment/root.zig");
const pane_input_commands = @import("../application/commands/pane_input.zig");
const pane_input_controller = @import("../entrypoints/requests/pane_input.zig");
const test_support = @import("support.zig");
const telemetry_mod = @import("../observability/root.zig").telemetry;

const schema = core.schema;
const diagnostics = core.diagnostics;
const Pane = pane_mod.Pane;
const AttachmentStore = attachment_mod.AttachmentStore;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;
const InputController = pane_input_controller.Controller(*pane_input_commands.PaneInputHandler);
const PaneFixture = test_support.PaneFixture;

const ScheduleStep = enum { observation, input };

const ScheduleCapture = struct {
    steps: [2]ScheduleStep = undefined,
    len: usize = 0,
    observation_failure: ?anyerror = null,
    input_failure: ?anyerror = null,
    observation_saw_history: bool = false,
    observation_saw_empty_input_queue: bool = false,
    input_saw_history: bool = false,
    expected_input: ?[]const u8 = null,
    input_matched: bool = false,

    fn scheduler(capture: *ScheduleCapture) pane_input_commands.Scheduler {
        return .{
            .context = capture,
            .observation = scheduleObservation,
            .input = scheduleInput,
        };
    }

    fn scheduleObservation(context: *anyopaque, pane: *Pane) !void {
        const capture: *ScheduleCapture = @ptrCast(@alignCast(context));
        capture.record(.observation);
        capture.observation_saw_history = pane.history_observer.hasPending();
        capture.observation_saw_empty_input_queue = pane.input_queue.nextChunk() == null;

        if (capture.observation_failure) |failure| {
            return failure;
        }
    }

    fn scheduleInput(context: *anyopaque, pane: *Pane) !void {
        const capture: *ScheduleCapture = @ptrCast(@alignCast(context));
        capture.record(.input);
        capture.input_saw_history = pane.history_observer.hasPending();

        if (capture.expected_input) |expected| {
            const queued = pane.input_queue.nextChunk() orelse return error.MissingQueuedInput;
            capture.input_matched = std.mem.eql(u8, expected, queued);
        }

        if (capture.input_failure) |failure| {
            return failure;
        }
    }

    fn record(capture: *ScheduleCapture, step: ScheduleStep) void {
        std.debug.assert(capture.len < capture.steps.len);
        capture.steps[capture.len] = step;
        capture.len += 1;
    }
};

fn handlerFor(fixture: *PaneFixture, capture: *ScheduleCapture, observe_agent_input: bool) pane_input_commands.PaneInputHandler {
    return .{
        .io = std.testing.io,
        .attachments = &fixture.attachments,
        .metrics = &fixture.metrics,
        .agent_input = if (observe_agent_input) &fixture.agents else null,
        .scheduler = capture.scheduler(),
    };
}

fn trackAgent(fixture: *PaneFixture) !agent_mod.Identity {
    const identity = agent_mod.Identity.fromPane(fixture.pane);
    try std.testing.expect(identity.process_id != 0);
    try std.testing.expect(fixture.agents.observeProcess(.{
        .identity = identity,
        .provider = .codex,
        .process_id = identity.process_id,
        .observed_at_ms = 100,
    }));
    return identity;
}

fn expectHandledMetrics(metrics: *const RuntimeMetrics, byte_count: usize) !void {
    const expected_events: u64 = if (comptime diagnostics.enabled) 1 else 0;
    const expected_bytes: u64 = if (comptime diagnostics.enabled) byte_count else 0;
    try std.testing.expectEqual(expected_events, metrics.input_events);
    try std.testing.expectEqual(expected_bytes, metrics.input_bytes);
}

test "PaneInputHandler rejects a pane outside the client attachments" {
    var attachments: AttachmentStore = .{};
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: ScheduleCapture = .{};
    var handler: pane_input_commands.PaneInputHandler = .{
        .io = std.testing.io,
        .attachments = &attachments,
        .metrics = &metrics,
        .agent_input = null,
        .scheduler = capture.scheduler(),
    };

    const result = try handler.execute(.{
        .pane_id = try schema.id.pane(99),
        .bytes = "x",
    });

    try std.testing.expectEqual(pane_input_commands.PaneInputResult.pane_not_attached, result);
    try std.testing.expectEqual(@as(usize, 0), capture.len);
    try std.testing.expectEqual(@as(u64, 0), metrics.input_events);
    try std.testing.expectEqual(@as(u64, 0), metrics.input_bytes);
}

test "PaneInputHandler rejects an exited attached pane before side effects" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.pane.exit = .{ .exited = 0 };
    var capture: ScheduleCapture = .{};
    var handler = handlerFor(&fixture, &capture, false);

    const result = try handler.execute(.{
        .pane_id = fixture.pane.id,
        .bytes = "x",
    });

    try std.testing.expectEqual(pane_input_commands.PaneInputResult.pane_exited, result);
    try std.testing.expectEqual(@as(usize, 0), capture.len);
    try std.testing.expect(!fixture.pane.history_observer.hasPending());
    try std.testing.expect(fixture.pane.input_queue.nextChunk() == null);
    try std.testing.expectEqual(@as(u64, 0), fixture.metrics.input_events);
    try std.testing.expectEqual(@as(u64, 0), fixture.metrics.input_bytes);
}

test "PaneInputHandler preserves input handling until the pane exit is observed" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    try std.testing.expect(fixture.pane.requestClose());
    var capture: ScheduleCapture = .{ .expected_input = "x" };
    var handler = handlerFor(&fixture, &capture, false);

    const result = try handler.execute(.{ .pane_id = fixture.pane.id, .bytes = "x" });

    try std.testing.expectEqual(pane_input_commands.PaneInputResult.handled, result);
    try std.testing.expectEqualSlices(ScheduleStep, &.{ .observation, .input }, capture.steps[0..capture.len]);
    try std.testing.expect(capture.input_matched);
}

test "pane input crosses controller and handler in observation-before-PTY order" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const identity = try trackAgent(&fixture);
    var input = [_]u8{ 'h', 'e', 'l', 'p', '\r' };
    var capture: ScheduleCapture = .{ .expected_input = &input };
    var handler = handlerFor(&fixture, &capture, true);
    var controller = InputController.init(&fixture.metrics, &handler);

    _ = try controller.paneInput(.{ .pane_id = fixture.pane.id, .bytes = &input });

    try std.testing.expectEqualSlices(ScheduleStep, &.{ .observation, .input }, capture.steps[0..capture.len]);
    try std.testing.expect(capture.observation_saw_history);
    try std.testing.expect(capture.observation_saw_empty_input_queue);
    try std.testing.expect(capture.input_saw_history);
    try std.testing.expect(capture.input_matched);
    try expectHandledMetrics(&fixture.metrics, input.len);
    try std.testing.expect(!fixture.agents.observeInput(identity.key, "later\r"));

    input[0] = 'X';
    try std.testing.expectEqualStrings("help\r", fixture.pane.input_queue.nextChunk().?);
}

test "PaneInputHandler leaves agent input untouched when descriptions are disabled" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const identity = try trackAgent(&fixture);
    var capture: ScheduleCapture = .{ .expected_input = "x" };
    var handler = handlerFor(&fixture, &capture, false);

    try std.testing.expectEqual(
        pane_input_commands.PaneInputResult.handled,
        try handler.execute(.{ .pane_id = fixture.pane.id, .bytes = "x" }),
    );

    try std.testing.expect(fixture.agents.observeInput(identity.key, "captured later\r"));
    try std.testing.expect(capture.input_matched);
}

test "PaneInputHandler stops before the PTY queue when observation scheduling fails" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var capture: ScheduleCapture = .{ .observation_failure = error.ObserverUnavailable };
    var handler = handlerFor(&fixture, &capture, false);

    try std.testing.expectError(error.ObserverUnavailable, handler.execute(.{
        .pane_id = fixture.pane.id,
        .bytes = "x",
    }));

    try std.testing.expectEqualSlices(ScheduleStep, &.{.observation}, capture.steps[0..capture.len]);
    try std.testing.expect(capture.observation_saw_history);
    try std.testing.expect(capture.observation_saw_empty_input_queue);
    try std.testing.expect(fixture.pane.input_queue.nextChunk() == null);
    try expectHandledMetrics(&fixture.metrics, 1);
}

test "PaneInputHandler preserves queued bytes when input scheduling fails" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var capture: ScheduleCapture = .{
        .input_failure = error.InputWriterUnavailable,
        .expected_input = "x",
    };
    var handler = handlerFor(&fixture, &capture, false);

    try std.testing.expectError(error.InputWriterUnavailable, handler.execute(.{
        .pane_id = fixture.pane.id,
        .bytes = "x",
    }));

    try std.testing.expectEqualSlices(ScheduleStep, &.{ .observation, .input }, capture.steps[0..capture.len]);
    try std.testing.expect(capture.input_matched);
    try std.testing.expectEqualStrings("x", fixture.pane.input_queue.nextChunk().?);
    try expectHandledMetrics(&fixture.metrics, 1);
}

test "PaneInputHandler drops one whole saturated message and schedules the backlog" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const block = [_]u8{'a'} ** schema.max_input_bytes;
    try std.testing.expect(fixture.pane.queuePtyInput(&block));
    try std.testing.expect(fixture.pane.queuePtyInput(&block));
    var capture: ScheduleCapture = .{};
    var handler = handlerFor(&fixture, &capture, false);

    try std.testing.expectEqual(
        pane_input_commands.PaneInputResult.handled,
        try handler.execute(.{ .pane_id = fixture.pane.id, .bytes = "drop" }),
    );

    try std.testing.expectEqualSlices(ScheduleStep, &.{ .observation, .input }, capture.steps[0..capture.len]);
    try std.testing.expectEqual(@as(usize, pane_mod.PaneInputQueue.capacity), fixture.pane.input_queue.len);
    try std.testing.expectEqual(@as(u64, "drop".len), fixture.pane.input_queue.dropped_bytes);
    try expectHandledMetrics(&fixture.metrics, "drop".len);
}
