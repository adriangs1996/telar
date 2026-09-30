//! Semantic input reaches a pane's child: client keystrokes, control-API
//! text and runtime responses queue on the pane and one bounded write per
//! kind runs at a time.
const agent_status = @import("agent_status.zig");

const pacing = @import("pacing");
const pane_observation = @import("pane_observation.zig");
const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const Pane = @import("../pane/Pane.zig");
const PaneInputQueue = @import("../pane/PaneInputQueue.zig");
const limit_reached = @import("limit_reached.zig");
const PaneKey = @import("../pane/PaneKey.zig");
const pane_namespace = @import("../pane/pane_namespace.zig");
const client_request = @import("client_request.zig");
const agent_control = @import("agent_control.zig");
const InputCompletion = @import("events/InputCompletion.zig");
const ResponseCompletion = @import("events/ResponseCompletion.zig");

const keyinput = @import("keyinput");

const paste_start = "\x1b[200~";
const paste_end = "\x1b[201~";
const legacy_enter = "\r";
const kitty_enter = "\x1b[13u";
const prompt_overhead = paste_start.len + paste_end.len + kitty_enter.len;

/// Forwards a client's keystrokes to an attached terminal pane.
///
/// ```zig
/// try pane_input.send(model, session, input);
/// ```
pub fn send(model: *RuntimeModel, session: *Session, input: core.PaneInput) !void {
    const attachment = model.attachments.find(session.slot, input.pane_id) orelse {
        model.metrics.stale_client_messages += 1;
        return;
    };
    const pane = attachment.pane;
    if (pane.exit != null) {
        model.metrics.stale_client_messages += 1;
        return;
    }

    _ = try forward(model, pane, input.bytes);
    recordOrigin(model, session, input.pane_id);
}

/// Types control-API text into one exact pane generation, framed as a
/// prompt submission when asked.
///
/// ```zig
/// try pane_input.sendText(model, session, request);
/// ```
pub fn sendText(model: *RuntimeModel, session: *Session, request: core.SendPaneText) !void {
    const key: PaneKey = .{ .id = request.pane_id, .generation = request.pane_generation };
    const pane = model.panes.resolveControl(key) orelse {
        return client_request.fail(session, request.request_id, .pane_not_found, "pane not found");
    };

    if (pane.exit != null) {
        return client_request.fail(session, request.request_id, .pane_exited, "pane already exited");
    }

    if (agent_control.focusedByClient(model, pane.id)) {
        return client_request.fail(session, request.request_id, .pane_focused, "the pane has the focus in an attached window");
    }

    var storage: [core.max_pane_text_input_bytes + agent_control.max_sender_line_bytes + prompt_overhead]u8 = undefined;
    const modes = pane.inputModeState();
    const bytes = switch (request.mode) {
        .raw => request.text,
        .raw_enter => submissionBytes(
            &storage,
            .{
                .text = request.text,
            },
            modes,
        ),
        .prompt => prompt: {
            if (agent_status.projectedStatus(model, pane.key()) == .blocked) {
                return client_request.fail(session, request.request_id, .agent_blocked, "agent is waiting for a decision");
            }

            var sender_buffer: [agent_control.max_sender_line_bytes]u8 = undefined;
            const known_sender = if (request.sender) |sender| if (model.panes.resolveControlConst(.{ .id = sender, .generation = 0 }) != null) sender else null else null;
            const sender_line = if (known_sender) |sender| line: {
                const now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds();
                if (!model.prompt_budget.spend(sender, pane.id, now_ms)) {
                    return client_request.fail(session, request.request_id, .prompt_rate_limited, "prompt budget for this pane is spent; wait for its answer");
                }

                break :line agent_control.senderLine(model, sender, &sender_buffer);
            } else "";

            break :prompt submissionBytes(
                &storage,
                .{
                    .prefix = sender_line,
                    .text = request.text,
                    .paste = true,
                },
                modes,
            );
        },
    };

    if (!try forward(model, pane, bytes)) {
        return client_request.fail(session, request.request_id, .resource_limit, input_queue_full);
    }

    if (request.mode != .raw or std.mem.indexOfScalar(u8, bytes, '\r') != null) {
        pane.noteInjectedSubmission();
    }

    try client_request.complete(session, request.request_id);
}

/// Presses keys such as an interrupt in a pane's child, encoded for the
/// keyboard mode the child enabled, through the same path as typed input
/// so history and agent observation see them.
///
/// ```zig
/// try pane_input.press(model, pane, &.{keyinput.Key.plain(.escape)});
/// ```
pub fn press(model: *RuntimeModel, pane: *Pane, keys: []const keyinput.Key) !void {
    const max_keys = 4;
    std.debug.assert(keys.len <= max_keys);
    var encoded: [max_keys * keyinput.max_key_bytes]u8 = undefined;
    const modes = pane.inputModeState();
    var len: usize = 0;

    for (keys) |key| {
        const bytes = try keyinput.encodeKey(encoded[len..], key, modes);
        len += bytes.len;
    }

    _ = try forward(model, pane, encoded[0..len]);
}

/// Queues bytes for a restored pane's child and starts the input write.
/// The bytes are a runtime-built resume command, never client input.
///
/// ```zig
/// try pane_input.sendRestored(model, pane, "claude --resume <id>\r");
/// ```
pub fn sendRestored(model: *RuntimeModel, pane: *Pane, bytes: []const u8) !void {
    if (!pane.queuePtyInput(bytes)) {
        reportFullQueue(model, pane, bytes.len);
        return;
    }

    if (std.mem.indexOfScalar(u8, bytes, '\r') != null) {
        pane.noteInjectedSubmission();
    }

    try startInputWrite(model, pane);
}

/// Releases one completed input write and starts the next queued one.
///
/// ```zig
/// try pane_input.finishInputWrite(model, completion);
/// ```
pub fn finishInputWrite(model: *RuntimeModel, completion: InputCompletion) !void {
    const pane = model.panes.resolve(completion.pane) orelse {
        model.metrics.stale_pane_events += 1;
        return;
    };

    const result: pane_namespace.PtyWriteResult = if (completion.result) |_| .succeeded else |_| .failed;
    pane.completePtyInputWrite(result);

    if (comptime core.enabled) {
        model.metrics.input_write.observe(core.elapsed(completion.started_ns, core.now(model.io)));
    }

    if (result == .succeeded) {
        try startInputWrite(model, pane);
    }
}

/// Releases one completed runtime-response write and starts the next.
///
/// ```zig
/// try pane_input.finishResponseWrite(model, completion);
/// ```
pub fn finishResponseWrite(model: *RuntimeModel, completion: ResponseCompletion) !void {
    const pane = model.panes.resolve(completion.pane) orelse {
        model.metrics.stale_pane_events += 1;
        return;
    };

    const result: pane_namespace.PtyWriteResult = if (completion.result) |_| .succeeded else |_| .failed;
    pane.completePtyResponseWrite(result);

    if (result == .succeeded) {
        try startResponseWrite(model, pane);
    }
}

/// Starts the pane's next queued input write unless one is in flight.
/// Example: `try pane_input.startInputWrite(model, pane);`.
pub fn startInputWrite(model: *RuntimeModel, pane: *Pane) !void {
    const bytes = pane.beginPtyInputWrite() orelse return;
    const write: InputWrite = .{
        .io = model.io,
        .pane = pane,
        .bytes = bytes,
        .started_ns = if (comptime core.enabled) core.now(model.io) else 0,
    };

    core.mark(model.io, .pty_write_queued);
    model.select.concurrent(.pane_input_written, writeInput, .{write}) catch |err| {
        pane.cancelPtyInputWrite();
        return err;
    };
}

/// Starts the pane's next queued terminal response unless one is in flight.
/// Example: `try pane_input.startResponseWrite(model, pane);`.
pub fn startResponseWrite(model: *RuntimeModel, pane: *Pane) !void {
    const bytes = pane.beginPtyResponseWrite() orelse return;
    const write: ResponseWrite = .{
        .io = model.io,
        .pane = pane,
        .bytes = bytes,
    };

    model.select.concurrent(.pane_response_written, writeResponse, .{write}) catch |err| {
        pane.cancelPtyResponseWrite();
        return err;
    };
}

/// What a control client reads when the pane's input queue has no room:
/// its child has stopped reading what it was sent.
pub const input_queue_full = std.fmt.comptimePrint("the pane's input queue holds its limit of {d} bytes; the program in it is not reading input", .{PaneInputQueue.capacity});

/// Queues `bytes` for the child whole, or nothing when they do not fit, in
/// which case the queue's limit is reported and neither history nor agent
/// observation sees bytes the child never gets.
fn forward(model: *RuntimeModel, pane: *Pane, bytes: []const u8) !bool {
    if (!pane.input_queue.fits(bytes.len)) {
        pane.input_queue.dropped_bytes +|= bytes.len;
        reportFullQueue(model, pane, bytes.len);
        return false;
    }

    core.mark(model.io, .input_forward);
    if (comptime core.enabled) {
        model.metrics.input_events += 1;
        model.metrics.input_bytes += bytes.len;
    }

    if (model.agent_description_options != null) {
        _ = agent_status.observeInput(model, pane.key(), bytes);
    }

    core.mark(model.io, .foreground_start);
    const slot = model.panes.index.get(core.raw(pane.id)).?;
    const foreground: ?bool = if (model.panes.shell_markers[slot]) null else pane.session.shellForeground() orelse false;
    core.mark(model.io, .foreground_done);
    pane.queueHistoryInput(.{
        .bytes = bytes,
        .shell_foreground = foreground,
        .clock = pane_namespace.historyClock(model.io),
    });
    core.mark(model.io, .input_observed);
    try pane_observation.start(model, pane);

    if (pane.queuePtyInput(bytes) and bytes.len != 0) {
        pane.cell_input_ns = pacing.clock.monotonic(model.io);
    }

    try startInputWrite(model, pane);
    return true;
}

fn reportFullQueue(model: *RuntimeModel, pane: *const Pane, len: usize) void {
    limit_reached.report(model, .{
        .limit = PaneInputQueue.limit,
        .requested = pane.input_queue.len + len,
    });
}

fn recordOrigin(model: *RuntimeModel, session: *Session, pane_id: core.PaneId) void {
    model.input_sequence +%= 1;
    if (model.input_sequence == 0) {
        for (&model.clients.items) |*slot| {
            const client = slot.* orelse continue;
            client.last_input_sequence = 0;
        }
        model.input_sequence = 1;
    }

    session.last_input_pane = pane_id;
    session.last_input_sequence = model.input_sequence;
}

fn writeInput(write: InputWrite) InputCompletion {
    core.mark(write.io, .pty_write_start);
    defer core.mark(write.io, .pty_write_done);
    const path = core.enter(.interactive);
    defer path.restore();

    write.pane.pty_write_mutex.lockUncancelable(write.io);
    defer write.pane.pty_write_mutex.unlock(write.io);

    return .{
        .pane = write.pane.key(),
        .started_ns = write.started_ns,
        .result = write.pane.session.writeAll(write.io, write.bytes),
    };
}

fn writeResponse(write: ResponseWrite) ResponseCompletion {
    const path = core.enter(.interactive);
    defer path.restore();

    write.pane.pty_write_mutex.lockUncancelable(write.io);
    defer write.pane.pty_write_mutex.unlock(write.io);

    return .{
        .pane = write.pane.key(),
        .result = write.pane.session.writeAll(write.io, write.bytes),
    };
}

/// Text that ends by pressing Enter, as a person would submit it.
const Submission = struct {
    /// Names the sending pane; written before the text, inside the paste.
    prefix: []const u8 = "",
    text: []const u8,
    /// Frames the text as a bracketed paste when the child enabled mode 2004.
    paste: bool = false,
};

fn submissionBytes(storage: *[core.max_pane_text_input_bytes + agent_control.max_sender_line_bytes + prompt_overhead]u8, submission: Submission, modes: keyinput.InputModes) []const u8 {
    std.debug.assert(submission.text.len <= core.max_pane_text_input_bytes);
    std.debug.assert(submission.prefix.len <= agent_control.max_sender_line_bytes);
    const bracketed = submission.paste and modes.bracketed_paste;
    var len: usize = 0;

    if (bracketed) {
        @memcpy(storage[len .. len + paste_start.len], paste_start);
        len += paste_start.len;
    }

    @memcpy(storage[len .. len + submission.prefix.len], submission.prefix);
    len += submission.prefix.len;
    @memcpy(storage[len .. len + submission.text.len], submission.text);
    len += submission.text.len;

    if (bracketed) {
        @memcpy(storage[len .. len + paste_end.len], paste_end);
        len += paste_end.len;
    }

    const enter = enterBytes(modes);
    @memcpy(storage[len .. len + enter.len], enter);
    len += enter.len;
    return storage[0..len];
}

/// The Enter key a submission ends with. A child that enabled the kitty
/// keyboard protocol receives `CSI 13 u`, which it cannot read as text:
/// Claude Code takes an unbracketed burst of 100 bytes or more for a paste
/// and keeps a carriage return inside it as part of the text. Any other
/// child receives the carriage return a terminal sends for Enter.
fn enterBytes(modes: keyinput.InputModes) []const u8 {
    if (modes.kitty_keyboard_flags != 0) {
        return kitty_enter;
    }

    return legacy_enter;
}

test "submissions frame a paste only when asked and the child enabled it" {
    var storage: [core.max_pane_text_input_bytes + agent_control.max_sender_line_bytes + prompt_overhead]u8 = undefined;
    const bracketed: keyinput.InputModes = .{
        .bracketed_paste = true,
    };
    const pasted: Submission = .{
        .text = "hello",
        .paste = true,
    };
    const typed: Submission = .{
        .text = "hello",
    };
    const named: Submission = .{
        .prefix = "[telar: from fix, pane 3] ",
        .text = "hi",
        .paste = true,
    };

    try std.testing.expectEqualStrings("hello\r", submissionBytes(
        &storage,
        pasted,
        .{},
    ));
    try std.testing.expectEqualStrings("\x1b[200~hello\x1b[201~\r", submissionBytes(
        &storage,
        pasted,
        bracketed,
    ));
    try std.testing.expectEqualStrings("hello\r", submissionBytes(
        &storage,
        typed,
        bracketed,
    ));
    try std.testing.expectEqualStrings("\x1b[200~[telar: from fix, pane 3] hi\x1b[201~\r", submissionBytes(
        &storage,
        named,
        bracketed,
    ));
}

test "submissions press Enter as the kitty protocol encodes it once the child enabled it" {
    var storage: [core.max_pane_text_input_bytes + agent_control.max_sender_line_bytes + prompt_overhead]u8 = undefined;
    const kitty: keyinput.InputModes = .{
        .bracketed_paste = true,
        .kitty_keyboard_flags = 0b101,
    };
    const typed: Submission = .{
        .text = "y",
    };
    const pasted: Submission = .{
        .text = "hi",
        .paste = true,
    };

    try std.testing.expectEqualStrings("y\x1b[13u", submissionBytes(
        &storage,
        typed,
        kitty,
    ));
    try std.testing.expectEqualStrings("\x1b[200~hi\x1b[201~\x1b[13u", submissionBytes(
        &storage,
        pasted,
        kitty,
    ));
}

const ResponseWrite = struct {
    /// Stable response borrowed from the queue until completion is handled.
    io: std.Io,
    pane: *Pane,
    bytes: []const u8,
};

const InputWrite = struct {
    /// Stable input borrowed from a pane until its completion event is handled.
    io: std.Io,
    pane: *Pane,
    bytes: []const u8,
    started_ns: u64,
};
