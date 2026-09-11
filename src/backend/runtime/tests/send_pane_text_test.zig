//! Vertical tests for text sent to a pane by a control client.

const GenericSendPaneTextController = @import("../entrypoints/requests/GenericSendPaneTextController.zig").Type;
const SendPaneTextHandlerType = @import("../application/commands/SendPaneTextHandler.zig");
const Harness = @import("Harness.zig");
const agent_identity = @import("../application/coordinators/agent_identity.zig");
const std = @import("std");
const AgentStatusType = @import("telar-core").AgentStatus;
const send_pane_text_commands = @import("../application/commands/send_pane_text.zig");
const FailureCodeType = @import("telar-core").FailureCode;

const SendPaneTextController = GenericSendPaneTextController(*SendPaneTextHandlerType);

fn blockAgent(harness: *Harness) !void {
    const identity = agent_identity.fromPane(harness.fixture.pane);
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
    try std.testing.expectEqual(AgentStatusType.blocked, harness.fixture.agents.projectedStatus(identity.key).?);
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
    try std.testing.expectEqual(FailureCodeType.agent_blocked, harness.responses.items[0].request_failed.code);

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
