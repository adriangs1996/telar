//! Agent control through the concrete request dispatch: the bytes text,
//! Enter and interrupt keys queue on a pane's PTY, and the rules that refuse
//! them.

const std = @import("std");
const core = @import("telar-core");
const EventFixture = @import("EventFixture.zig");
const Pane = @import("../../pane/Pane.zig");
const PromptBudget = @import("../../agent/PromptBudget.zig");
const types = @import("../../agent/types.zig");
const agent_control = @import("../agent_control.zig");
const agent_identity = @import("../agent_identity.zig");
const agent_status = @import("../agent_status.zig");

const request_id: core.RequestId = @enumFromInt(41);
const kitty_keyboard = "\x1b[>5u";
const bracketed_paste = "\x1b[?2004h";

/// Holds the pane's PTY writer busy so what a request queued stays readable.
fn holdWrites(pane: *Pane) void {
    pane.input_write_pending = true;
}

fn releaseWrites(pane: *Pane) void {
    pane.input_write_pending = false;
    pane.input_queue.clear();
}

fn queued(pane: *const Pane) []const u8 {
    return pane.input_queue.nextChunk() orelse "";
}

fn sendText(fixture: *EventFixture, mode: core.PaneTextMode, text: []const u8) !void {
    try fixture.request.send(.{ .send_pane_text = .{
        .request_id = request_id,
        .pane_id = fixture.pane.id,
        .pane_generation = fixture.pane.generation,
        .mode = mode,
        .text = text,
    } });
}

fn interrupt(fixture: *EventFixture) !void {
    try fixture.request.send(.{ .interrupt_agent = .{
        .request_id = request_id,
        .pane_id = fixture.pane.id,
        .pane_generation = fixture.pane.generation,
    } });
}

fn expectCompleted(fixture: *EventFixture) !void {
    const response = fixture.request.response() orelse return error.MissingReply;
    try std.testing.expect(response.* == .request_completed);
    fixture.request.clearResponses();
}

fn expectFailure(fixture: *EventFixture, code: core.FailureCode) !void {
    const response = fixture.request.response() orelse return error.MissingReply;
    try std.testing.expect(response.* == .request_failed);
    try std.testing.expectEqual(code, response.request_failed.code);
    fixture.request.clearResponses();
}

fn ingest(pane: *Pane, bytes: []const u8) !void {
    _ = try pane.ingest(std.testing.io, bytes);
}

/// Registers a Claude Code agent in the fixture pane with a working turn.
fn startClaudeTurn(fixture: *EventFixture) !void {
    const identity = agent_identity.fromPane(fixture.pane);
    const now_ms = std.Io.Timestamp.now(std.testing.io, .real).toMilliseconds();
    _ = agent_status.observeProcess(fixture.model, .{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = now_ms,
    });
    _ = agent_status.observeReport(fixture.model, .{
        .identity = identity,
        .state = .working,
        .observed_at_ms = now_ms,
        .observed_at_ns = 1_000,
    });
    try std.testing.expectEqual(core.AgentStatus.working, agent_status.projectedStatus(fixture.model, fixture.pane.key()).?);
}

/// Observes a Claude Code screen drawn after the interrupt, `after_ms` past
/// `start_ms`; `idle` draws the idle composer, otherwise the restored draft.
fn observeScreen(fixture: *EventFixture, start_ms: i64, after_ms: i64, idle: bool) void {
    const now = std.Io.Timestamp.now(std.testing.io, .awake).toNanoseconds();
    _ = agent_status.observeScreen(fixture.model, .{
        .identity = agent_identity.fromPane(fixture.pane),
        .signal = .{
            .provider = .claude,
            .status = .ready,
            .confidence = if (idle) 96 else 90,
            .identity_confirmed = true,
            .ready_confirmed = idle,
        },
        .observed_at_ms = start_ms + after_ms,
        .observed_at_ns = @intCast(now + 1 + after_ms * std.time.ns_per_ms),
    });
}

fn status(fixture: *EventFixture) core.AgentStatus {
    return agent_status.projectedStatus(fixture.model, fixture.pane.key()).?;
}

/// Makes the fixture's UI client report the pane as focused in its active tab.
fn focusPane(fixture: *EventFixture) void {
    const identity: core.ClientIdentity = @enumFromInt(5);
    fixture.request.session.delivery.client_identity = identity;
    const record = &fixture.model.client_layouts.records[0];
    record.identity = identity;
    record.active_tab = fixture.pane.location;
    record.tabs[0] = .{
        .location = fixture.pane.location,
        .focused_pane = fixture.pane.id,
        .fullscreen = false,
        .workspace_active = true,
        .node_start = 0,
        .node_count = 0,
    };
    record.tab_count = 1;
}

test "raw text reaches the PTY unchanged and raw_enter adds the Enter a shell reads" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    holdWrites(fixture.pane);
    defer releaseWrites(fixture.pane);

    try sendText(&fixture, .raw, "y");
    try expectCompleted(&fixture);
    try std.testing.expectEqualStrings("y", queued(fixture.pane));

    fixture.pane.input_queue.clear();
    try sendText(&fixture, .raw_enter, "ls");
    try expectCompleted(&fixture);
    try std.testing.expectEqualStrings("ls\r", queued(fixture.pane));

    fixture.pane.input_queue.clear();
    try sendText(&fixture, .raw_enter, "");
    try expectCompleted(&fixture);
    try std.testing.expectEqualStrings("\r", queued(fixture.pane));
}

test "text that does not fit the pane's input queue fails the request and keeps what was queued" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    holdWrites(fixture.pane);
    defer releaseWrites(fixture.pane);

    const queue = &fixture.pane.input_queue;
    const filler: [core.max_input_bytes]u8 = @splat('f');
    while (queue.fits(filler.len)) {
        try std.testing.expect(queue.push(&filler));
    }

    const room = queue.bytes.len - queue.len;
    const text: [core.max_pane_text_input_bytes]u8 = @splat('t');
    try std.testing.expect(room < text.len);
    const queued_before = queue.len;
    try sendText(&fixture, .raw, &text);
    const responses = &fixture.request.session.delivery.responses;
    try std.testing.expect(responses.peek().?.* == .notification);
    responses.pop();
    try expectFailure(&fixture, .resource_limit);
    try std.testing.expectEqual(queued_before, queue.len);
    try std.testing.expectEqual(@as(u64, text.len), queue.dropped_bytes);
    try std.testing.expect(fixture.model.limit_reaches.find("panes.input_queue_capacity") != null);
}

test "Enter follows the kitty keyboard protocol once the child enables it" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    holdWrites(fixture.pane);
    defer releaseWrites(fixture.pane);
    try ingest(fixture.pane, kitty_keyboard ++ bracketed_paste);

    try sendText(&fixture, .raw_enter, "");
    try expectCompleted(&fixture);
    try std.testing.expectEqualStrings("\x1b[13u", queued(fixture.pane));

    fixture.pane.input_queue.clear();
    try sendText(&fixture, .prompt, "run the tests");
    try expectCompleted(&fixture);
    try std.testing.expectEqualStrings("\x1b[200~run the tests\x1b[201~\x1b[13u", queued(fixture.pane));
}

test "text never reaches the pane a person has focused" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    holdWrites(fixture.pane);
    defer releaseWrites(fixture.pane);
    focusPane(&fixture);

    try sendText(&fixture, .raw_enter, "y");
    try expectFailure(&fixture, .pane_focused);
    try startClaudeTurn(&fixture);
    try interrupt(&fixture);
    try expectFailure(&fixture, .pane_focused);
    try std.testing.expectEqualStrings("", queued(fixture.pane));
}

test "prompts from one pane to another spend a budget per window" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    holdWrites(fixture.pane);
    defer releaseWrites(fixture.pane);
    // Any pane the runtime knows can send; the budget counts per pair.
    const prompt: core.SendPaneText = .{
        .request_id = request_id,
        .pane_id = fixture.pane.id,
        .pane_generation = fixture.pane.generation,
        .mode = .prompt,
        .text = "status?",
        .sender = fixture.pane.id,
    };

    for (0..PromptBudget.prompts_per_window) |_| {
        try fixture.request.send(.{ .send_pane_text = prompt });
        try expectCompleted(&fixture);
    }

    const accepted = fixture.pane.input_queue.len;
    try fixture.request.send(.{ .send_pane_text = prompt });
    try expectFailure(&fixture, .prompt_rate_limited);
    try std.testing.expectEqual(accepted, fixture.pane.input_queue.len);
    try std.testing.expect(std.mem.indexOf(u8, queued(fixture.pane), "[telar: from ") != null);
}

test "an interrupt presses Ctrl+C for Claude Code and keeps the turn working until the idle prompt holds" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    holdWrites(fixture.pane);
    defer releaseWrites(fixture.pane);
    try ingest(fixture.pane, kitty_keyboard);
    try startClaudeTurn(&fixture);
    const start_ms = std.Io.Timestamp.now(std.testing.io, .real).toMilliseconds();

    try interrupt(&fixture);
    try expectCompleted(&fixture);
    try std.testing.expectEqualStrings("\x1b[99;5u", queued(fixture.pane));
    try std.testing.expectEqual(core.AgentStatus.working, status(&fixture));

    try interrupt(&fixture);
    try expectCompleted(&fixture);
    try std.testing.expectEqualStrings("\x1b[99;5u", queued(fixture.pane));

    observeScreen(&fixture, start_ms, 10, true);
    _ = agent_status.expire(fixture.model, start_ms + 10 + types.interrupt_idle_ms - 1);
    try std.testing.expectEqual(core.AgentStatus.working, status(&fixture));

    _ = agent_status.expire(fixture.model, start_ms + 10 + types.interrupt_idle_ms);
    try std.testing.expect(status(&fixture) != .working);
}

test "a screen between the idle title and the restored draft restarts the wait" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    holdWrites(fixture.pane);
    defer releaseWrites(fixture.pane);
    try startClaudeTurn(&fixture);
    const start_ms = std.Io.Timestamp.now(std.testing.io, .real).toMilliseconds();
    try interrupt(&fixture);
    try expectCompleted(&fixture);

    observeScreen(&fixture, start_ms, 10, true);
    observeScreen(&fixture, start_ms, 11, false);
    _ = agent_status.expire(fixture.model, start_ms + 10 + types.interrupt_idle_ms);
    try std.testing.expectEqual(core.AgentStatus.working, status(&fixture));

    observeScreen(&fixture, start_ms, 400, true);
    _ = agent_status.expire(fixture.model, start_ms + 400 + types.interrupt_idle_ms);
    try std.testing.expect(status(&fixture) != .working);
}

test "an interrupt refuses an idle agent and one without an interrupt key" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    holdWrites(fixture.pane);
    defer releaseWrites(fixture.pane);

    try interrupt(&fixture);
    try expectFailure(&fixture, .agent_not_working);

    const identity = agent_identity.fromPane(fixture.pane);
    _ = agent_status.observeReport(fixture.model, .{
        .identity = identity,
        .state = .working,
        .observed_at_ms = 1_000,
    });
    try interrupt(&fixture);
    try expectFailure(&fixture, .interrupt_unsupported);
    try std.testing.expectEqualStrings("", queued(fixture.pane));
}

test "an interrupted Claude Code turn that restored its prompt gets one more Ctrl+C to clear it" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    holdWrites(fixture.pane);
    defer releaseWrites(fixture.pane);
    try startClaudeTurn(&fixture);
    try interrupt(&fixture);
    try expectCompleted(&fixture);
    try std.testing.expectEqualStrings("\x03", queued(fixture.pane));
    fixture.pane.input_queue.clear();

    try ingest(fixture.pane, "\x1b]0;\u{2733} Essay\x07\x1b[H\x1b[2J\u{276f} \x1b[3;1H\u{276f} write it");
    try agent_control.clearRestoredDraft(fixture.model, fixture.pane);
    try std.testing.expectEqualStrings("\x03", queued(fixture.pane));

    fixture.pane.input_queue.clear();
    try agent_control.clearRestoredDraft(fixture.model, fixture.pane);
    try std.testing.expectEqualStrings("", queued(fixture.pane));
}

test "an interrupted turn whose composer is empty or still spinning gets no extra key" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    holdWrites(fixture.pane);
    defer releaseWrites(fixture.pane);
    try startClaudeTurn(&fixture);
    try interrupt(&fixture);
    try expectCompleted(&fixture);
    fixture.pane.input_queue.clear();

    try ingest(fixture.pane, "\x1b]0;\u{25d0} Essay\x07\x1b[H\x1b[2J\u{276f} write it");
    try agent_control.clearRestoredDraft(fixture.model, fixture.pane);
    try ingest(fixture.pane, "\x1b]0;\u{2733} Essay\x07\x1b[H\x1b[2J\u{276f}\u{a0}");
    try agent_control.clearRestoredDraft(fixture.model, fixture.pane);
    try ingest(fixture.pane, "\x1b[H\x1b[2J\u{276f}\u{a0}\x1b[2mTry \"fix lint\"\x1b[22m");
    try agent_control.clearRestoredDraft(fixture.model, fixture.pane);
    try ingest(fixture.pane, "\x1b]0;clear; claude\x07\x1b[H\x1b[2J\u{276f} write it");
    try agent_control.clearRestoredDraft(fixture.model, fixture.pane);
    try std.testing.expectEqualStrings("", queued(fixture.pane));
}

test "a restored draft stays in a pane a person focused after the interrupt" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    holdWrites(fixture.pane);
    defer releaseWrites(fixture.pane);
    try startClaudeTurn(&fixture);
    try interrupt(&fixture);
    try expectCompleted(&fixture);
    fixture.pane.input_queue.clear();

    focusPane(&fixture);
    try ingest(fixture.pane, "\x1b]0;\u{2733} Essay\x07\x1b[H\x1b[2J\u{276f} their own words");
    try agent_control.clearRestoredDraft(fixture.model, fixture.pane);

    try std.testing.expectEqualStrings("", queued(fixture.pane));
}

test "a repeated interrupt presses again once the last press is old enough" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    holdWrites(fixture.pane);
    defer releaseWrites(fixture.pane);
    try startClaudeTurn(&fixture);
    try interrupt(&fixture);
    try expectCompleted(&fixture);
    fixture.pane.input_queue.clear();

    try interrupt(&fixture);
    try expectCompleted(&fixture);
    try std.testing.expectEqualStrings("", queued(fixture.pane));

    fixture.model.agents.find(fixture.pane.key()).?.interrupt_pressed_at_ms -= types.interrupt_repress_ms;
    try interrupt(&fixture);
    try expectCompleted(&fixture);
    try std.testing.expectEqualStrings("\x03", queued(fixture.pane));
    try std.testing.expectEqual(core.AgentStatus.working, status(&fixture));
}

test "an agent whose screen cannot show it idle settles its interrupt after a fixed wait" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    holdWrites(fixture.pane);
    defer releaseWrites(fixture.pane);
    const identity = agent_identity.fromPane(fixture.pane);
    const now_ms = std.Io.Timestamp.now(std.testing.io, .real).toMilliseconds();
    _ = agent_status.observeProcess(fixture.model, .{
        .identity = identity,
        .provider = .opencode,
        .process_id = 84,
        .observed_at_ms = now_ms,
    });
    _ = agent_status.observeReport(fixture.model, .{
        .identity = identity,
        .state = .working,
        .observed_at_ms = now_ms,
        .observed_at_ns = 1_000,
    });

    try interrupt(&fixture);
    try expectCompleted(&fixture);
    try std.testing.expectEqualStrings("\x1b\x1b", queued(fixture.pane));
    const pressed_at_ms = fixture.model.agents.find(fixture.pane.key()).?.interrupt_pressed_at_ms;

    _ = agent_status.expire(fixture.model, pressed_at_ms + types.interrupt_blind_ms - 1);
    try std.testing.expectEqual(core.AgentStatus.working, status(&fixture));
    _ = agent_status.expire(fixture.model, pressed_at_ms + types.interrupt_blind_ms);
    try std.testing.expect(status(&fixture) != .working);
}
