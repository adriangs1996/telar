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
const PaneKey = @import("../pane/PaneKey.zig");
const pane_namespace = @import("../pane/pane_namespace.zig");
const client_request = @import("client_request.zig");
const agent_control = @import("agent_control.zig");
const InputCompletion = @import("events/InputCompletion.zig");
const ResponseCompletion = @import("events/ResponseCompletion.zig");

const paste_start = "\x1b[200~";
const paste_end = "\x1b[201~";
const enter = "\r";
const prompt_overhead = paste_start.len + paste_end.len + enter.len;

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

    try forward(model, pane, input.bytes);
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
        return client_request.fail(session, request.request_id, .pane_focused, "a person is typing in this pane");
    }

    var storage: [core.max_pane_text_input_bytes + agent_control.max_sender_line_bytes + prompt_overhead]u8 = undefined;
    const bytes = switch (request.mode) {
        .raw => request.text,
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

            break :prompt promptBytes(&storage, .{
                .prefix = sender_line,
                .text = request.text,
            }, pane.terminal.modes.get(.bracketed_paste));
        },
    };

    try forward(model, pane, bytes);
    if (request.mode == .prompt or std.mem.indexOfScalar(u8, bytes, '\r') != null) {
        pane.noteInjectedSubmission();
    }

    try client_request.complete(session, request.request_id);
}

/// Forwards control bytes such as an interrupt key through the same path as
/// typed input, so history and agent observation see them.
///
/// ```zig
/// try pane_input.forwardControl(model, pane, "\x1b");
/// ```
pub fn forwardControl(model: *RuntimeModel, pane: *Pane, bytes: []const u8) !void {
    try forward(model, pane, bytes);
}

/// Queues bytes for a restored pane's child and starts the input write.
/// The bytes are a runtime-built resume command, never client input.
///
/// ```zig
/// try pane_input.sendRestored(model, pane, "claude --resume <id>\r");
/// ```
pub fn sendRestored(model: *RuntimeModel, pane: *Pane, bytes: []const u8) !void {
    if (std.mem.indexOfScalar(u8, bytes, '\r') != null) {
        pane.noteInjectedSubmission();
    }

    _ = pane.queuePtyInput(bytes);
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

fn forward(model: *RuntimeModel, pane: *Pane, bytes: []const u8) !void {
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

/// Frames one prompt the way a terminal paste followed by Enter would arrive.
const PromptText = struct {
    /// Names the sending pane; written inside the paste, before the text.
    prefix: []const u8 = "",
    text: []const u8,
};

fn promptBytes(storage: *[core.max_pane_text_input_bytes + agent_control.max_sender_line_bytes + prompt_overhead]u8, prompt: PromptText, bracketed: bool) []const u8 {
    std.debug.assert(prompt.text.len <= core.max_pane_text_input_bytes);
    std.debug.assert(prompt.prefix.len <= agent_control.max_sender_line_bytes);
    var len: usize = 0;

    if (bracketed) {
        @memcpy(storage[len .. len + paste_start.len], paste_start);
        len += paste_start.len;
    }

    @memcpy(storage[len .. len + prompt.prefix.len], prompt.prefix);
    len += prompt.prefix.len;
    @memcpy(storage[len .. len + prompt.text.len], prompt.text);
    len += prompt.text.len;

    if (bracketed) {
        @memcpy(storage[len .. len + paste_end.len], paste_end);
        len += paste_end.len;
    }

    @memcpy(storage[len .. len + enter.len], enter);
    len += enter.len;
    return storage[0..len];
}

test "promptBytes frames a paste only when the child asked for it" {
    var storage: [core.max_pane_text_input_bytes + agent_control.max_sender_line_bytes + prompt_overhead]u8 = undefined;

    try std.testing.expectEqualStrings("hello\r", promptBytes(&storage, .{ .text = "hello" }, false));
    try std.testing.expectEqualStrings("\x1b[200~hello\x1b[201~\r", promptBytes(&storage, .{ .text = "hello" }, true));
    try std.testing.expectEqualStrings("\x1b[200~[telar: from fix, pane 3] hi\x1b[201~\r", promptBytes(&storage, .{ .prefix = "[telar: from fix, pane 3] ", .text = "hi" }, true));
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
