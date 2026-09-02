//! Vertical tests for text sent to a pane by a control client.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../agent/root.zig");
const pane_mod = @import("../../pane/root.zig");
const delivery_mod = @import("../delivery/root.zig");
const pane_input_commands = @import("../application/commands/pane_input.zig");
const send_pane_text_commands = @import("../application/commands/send_pane_text.zig");
const send_pane_text_controller = @import("../entrypoints/requests/send_pane_text.zig");
const test_support = @import("support.zig");

const schema = core.schema;
const Pane = pane_mod.Pane;
const PaneFixture = test_support.PaneFixture;
const SendPaneTextController = send_pane_text_controller.Controller(*send_pane_text_commands.SendPaneTextHandler);

const ScheduleCapture = struct {
    observation_calls: usize = 0,
    input_calls: usize = 0,
    queued: ?[]const u8 = null,
    queued_storage: [256]u8 = undefined,

    fn scheduler(capture: *ScheduleCapture) pane_input_commands.Scheduler {
        return .{
            .context = capture,
            .observation = scheduleObservation,
            .input = scheduleInput,
        };
    }

    fn scheduleObservation(context: *anyopaque, _: *Pane) !void {
        const capture: *ScheduleCapture = @ptrCast(@alignCast(context));
        capture.observation_calls += 1;
    }

    fn scheduleInput(context: *anyopaque, pane: *Pane) !void {
        const capture: *ScheduleCapture = @ptrCast(@alignCast(context));
        capture.input_calls += 1;
        const chunk = pane.input_queue.nextChunk() orelse return error.MissingQueuedInput;
        @memcpy(capture.queued_storage[0..chunk.len], chunk);
        capture.queued = capture.queued_storage[0..chunk.len];
    }
};

const Harness = struct {
    fixture: PaneFixture = .{},
    panes: pane_mod.PaneStore = .{},
    capture: ScheduleCapture = .{},
    responses: delivery_mod.ResponseQueue = .{},

    fn init(harness: *Harness) !void {
        try harness.fixture.init();
        errdefer harness.fixture.deinit();
        try harness.panes.insert(harness.fixture.pane);
    }

    fn deinit(harness: *Harness) void {
        harness.fixture.deinit();
    }

    fn handler(harness: *Harness) send_pane_text_commands.SendPaneTextHandler {
        return .{
            .panes = &harness.panes,
            .agents = &harness.fixture.agents,
            .input = .{
                .io = std.testing.io,
                .metrics = &harness.fixture.metrics,
                .agent_input = &harness.fixture.agents,
                .scheduler = harness.capture.scheduler(),
            },
        };
    }

    fn key(harness: *const Harness) pane_mod.PaneKey {
        return harness.fixture.pane.key();
    }
};

fn blockAgent(harness: *Harness) !void {
    const identity = agent_mod.Identity.fromPane(harness.fixture.pane);
    try std.testing.expect(harness.fixture.agents.observeProcess(.{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 50,
    }));
    try std.testing.expect(harness.fixture.agents.observeScreen(.{
        .identity = identity,
        .signal = .{ .provider = .claude, .status = .blocked, .confidence = 90, .identity_confirmed = true },
        .observed_at_ms = 1_000,
    }));
    try std.testing.expectEqual(schema.AgentStatus.blocked, harness.fixture.agents.projectedStatus(identity.key).?);
}

test "a prompt reaches the PTY queue with Enter and is confirmed" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();
    var handler = harness.handler();
    var controller = SendPaneTextController.init(&harness.responses, &handler);

    try controller.sendPaneText(.{
        .request_id = @enumFromInt(2),
        .pane_id = harness.key().id,
        .pane_generation = harness.key().generation,
        .mode = .prompt,
        .text = "run the tests",
    });

    try std.testing.expectEqualStrings("run the tests\r", harness.capture.queued.?);
    try std.testing.expectEqual(@as(usize, 1), harness.capture.observation_calls);
    try std.testing.expectEqual(@as(usize, 1), harness.capture.input_calls);
    try std.testing.expect(harness.responses.items[0] == .request_completed);
}

test "a prompt is wrapped in bracketed paste once the child enables it" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();
    _ = try harness.fixture.pane.ingest(std.testing.io, "\x1b[?2004h");
    var handler = harness.handler();

    const result = try handler.execute(.{ .pane = harness.key(), .mode = .prompt, .text = "hi" });

    try std.testing.expectEqual(send_pane_text_commands.SendPaneTextResult.handled, result);
    try std.testing.expectEqualStrings("\x1b[200~hi\x1b[201~\r", harness.capture.queued.?);
}

test "raw text is forwarded byte for byte" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();
    _ = try harness.fixture.pane.ingest(std.testing.io, "\x1b[?2004h");
    var handler = harness.handler();

    const result = try handler.execute(.{ .pane = harness.key(), .mode = .raw, .text = "\x03" });

    try std.testing.expectEqual(send_pane_text_commands.SendPaneTextResult.handled, result);
    try std.testing.expectEqualStrings("\x03", harness.capture.queued.?);
}

test "a prompt to a blocked agent is refused before any byte is queued" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();
    try blockAgent(&harness);
    var handler = harness.handler();
    var controller = SendPaneTextController.init(&harness.responses, &handler);

    try controller.sendPaneText(.{
        .request_id = @enumFromInt(5),
        .pane_id = harness.key().id,
        .pane_generation = harness.key().generation,
        .mode = .prompt,
        .text = "continue",
    });

    try std.testing.expectEqual(@as(usize, 0), harness.capture.input_calls);
    try std.testing.expectEqual(schema.FailureCode.agent_blocked, harness.responses.items[0].request_failed.code);

    const raw = try handler.execute(.{ .pane = harness.key(), .mode = .raw, .text = "y" });
    try std.testing.expectEqual(send_pane_text_commands.SendPaneTextResult.handled, raw);
}

test "a stale generation is refused as pane_not_found" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();
    var handler = harness.handler();

    const result = try handler.execute(.{
        .pane = .{ .id = harness.key().id, .generation = harness.key().generation + 1 },
        .mode = .prompt,
        .text = "hello",
    });

    try std.testing.expectEqual(send_pane_text_commands.SendPaneTextResult.pane_not_found, result);
    try std.testing.expectEqual(@as(usize, 0), harness.capture.input_calls);
}
