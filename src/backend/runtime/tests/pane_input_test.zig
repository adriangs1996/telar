//! Vertical and application tests for the runtime pane-input flow.

const GenericPaneInputController = @import("../entrypoints/requests/GenericPaneInputController.zig").Type;
const PaneInputHandlerType = @import("../application/commands/PaneInputHandler.zig");
const PaneFixture = @import("PaneFixture.zig");
const PaneInputTestScheduleCapture = @import("PaneInputTestScheduleCapture.zig");
const std = @import("std");
const IdentityType = @import("../../agent/Identity.zig");
const agent_identity = @import("../application/coordinators/agent_identity.zig");
const RuntimeMetrics = @import("../observability/RuntimeMetrics.zig");
const enabled_module = @import("telar-core").enabled;
const AttachmentStore = @import("../attachment/AttachmentStore.zig");
const pane_module = @import("telar-core").pane;
const pane_input_commands = @import("../application/commands/pane_input.zig");
const max_input_bytes_module = @import("telar-core").max_input_bytes;
const PaneInputQueueType = @import("../../pane/PaneInputQueue.zig");

const InputController = GenericPaneInputController(*PaneInputHandlerType);

pub const ScheduleStep = enum { observation, input };

fn handlerFor(fixture: *PaneFixture, capture: *PaneInputTestScheduleCapture, observe_agent_input: bool) PaneInputHandlerType {
    return .{
        .io = std.testing.io,
        .attachments = &fixture.attachments,
        .metrics = &fixture.metrics,
        .agent_input = if (observe_agent_input) &fixture.agents else null,
        .scheduler = capture.scheduler(),
    };
}

fn trackAgent(fixture: *PaneFixture) !IdentityType {
    const identity = agent_identity.fromPane(fixture.pane);
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
    const expected_events: u64 = if (comptime enabled_module) 1 else 0;
    const expected_bytes: u64 = if (comptime enabled_module) byte_count else 0;
    try std.testing.expectEqual(expected_events, metrics.input_events);
    try std.testing.expectEqual(expected_bytes, metrics.input_bytes);
}

test "PaneInputHandler rejects a pane outside the client attachments" {
    var attachments: AttachmentStore = .{};
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: PaneInputTestScheduleCapture = .{};
    var handler: PaneInputHandlerType = .{
        .io = std.testing.io,
        .attachments = &attachments,
        .metrics = &metrics,
        .agent_input = null,
        .scheduler = capture.scheduler(),
    };

    const result = try handler.execute(.{
        .pane_id = try pane_module(99),
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
    var capture: PaneInputTestScheduleCapture = .{};
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
    var capture: PaneInputTestScheduleCapture = .{ .expected_input = "x" };
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
    var capture: PaneInputTestScheduleCapture = .{ .expected_input = &input };
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
    var capture: PaneInputTestScheduleCapture = .{ .expected_input = "x" };
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
    var capture: PaneInputTestScheduleCapture = .{ .observation_failure = error.ObserverUnavailable };
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
    var capture: PaneInputTestScheduleCapture = .{
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
    const block = [_]u8{'a'} ** max_input_bytes_module;
    try std.testing.expect(fixture.pane.queuePtyInput(&block));
    try std.testing.expect(fixture.pane.queuePtyInput(&block));
    var capture: PaneInputTestScheduleCapture = .{};
    var handler = handlerFor(&fixture, &capture, false);

    try std.testing.expectEqual(
        pane_input_commands.PaneInputResult.handled,
        try handler.execute(.{ .pane_id = fixture.pane.id, .bytes = "drop" }),
    );

    try std.testing.expectEqualSlices(ScheduleStep, &.{ .observation, .input }, capture.steps[0..capture.len]);
    try std.testing.expectEqual(@as(usize, PaneInputQueueType.capacity), fixture.pane.input_queue.len);
    try std.testing.expectEqual(@as(u64, "drop".len), fixture.pane.input_queue.dropped_bytes);
    try expectHandledMetrics(&fixture.metrics, "drop".len);
}
