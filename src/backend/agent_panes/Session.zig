const std = @import("std");
const core = @import("telar-core");
const Options = @import("Options.zig");
const Codex = @import("Codex.zig");
const Stream = @import("Stream.zig");
const protocol = @import("protocol.zig");
const Command = @import("command.zig").Command;
const Prompt = @import("Prompt.zig");
const ThreadMetadata = @import("ThreadMetadata.zig");
const HistoryOptions = @import("HistoryOptions.zig");
const Session = @This();

gpa: std.mem.Allocator,
history_options: *HistoryOptions,
startup_timeout_ms: u32,
worker: ?std.Io.Future(void) = null,
commands: std.Io.Queue(Command) = undefined,
command_storage: [protocol.queue_depth]Command = undefined,
changes: std.Io.Queue(u8) = undefined,
change_storage: [1]u8 = undefined,
stopping: std.atomic.Value(bool) = .init(false),
ready: std.atomic.Value(bool) = .init(false),
prompt_pending: std.atomic.Value(bool) = .init(false),
accepted_prompt: ?Prompt = null,
reserved: core.RecentConversation = .{},
resume_queued: bool = false,
mutex: std.Io.Mutex = .init,
published: core.AgentThreadSnapshot,
published_metadata: ThreadMetadata = .{},
codex: Codex,
stream: Stream = undefined,
output_frame: @import("OutputFrame.zig") = .{},
json_storage: [protocol.max_json_bytes]u8 = undefined,

/// Starts a bounded observation actor. Process spawn and JSON run on that actor.
/// Example: `const session = try Session.init(io, gpa, options);`
pub fn init(io: std.Io, gpa: std.mem.Allocator, options: Options) !*Session {
    if (!std.fs.path.isAbsolute(options.cwd) or options.arguments.len == 0) {
        return error.InvalidAgentOptions;
    }

    const session = try gpa.create(Session);
    errdefer gpa.destroy(session);
    const cwd = try gpa.dupe(u8, options.cwd);
    errdefer gpa.free(cwd);
    const arguments = try gpa.alloc([]const u8, options.arguments.len);
    errdefer gpa.free(arguments);
    var copied: usize = 0;
    errdefer for (arguments[0..copied]) |argument| gpa.free(argument);
    for (options.arguments, 0..) |argument, index| {
        arguments[index] = try gpa.dupe(u8, argument);
        copied += 1;
    }

    var environment = try options.environment.createMap(gpa);
    errdefer environment.deinit();
    var index: usize = 0;
    while (index < environment.keys().len) {
        const key = environment.keys()[index];
        if (std.mem.startsWith(u8, key, "TELAR_")) {
            _ = environment.swapRemove(key);
        } else {
            index += 1;
        }
    }

    const history_options = try gpa.create(HistoryOptions);
    errdefer gpa.destroy(history_options);
    history_options.* = .{ .gpa = gpa, .cwd = cwd, .arguments = arguments, .environment = environment };

    session.* = .{
        .gpa = gpa,
        .history_options = history_options,
        .startup_timeout_ms = options.startup_timeout_ms,
        .published = .{ .pane_id = options.pane_id, .pane_generation = options.pane_generation },
        .codex = .{ .cwd = cwd, .transcript = .{ .value = .{ .pane_id = options.pane_id, .pane_generation = options.pane_generation } } },
    };
    if (options.restore_conversation) |conversation| {
        _ = try core.RecentConversation.init(conversation.idSlice(), "");
        session.reserved = conversation;
        session.published.thread_id = conversation.id;
        session.published.thread_id_len = conversation.id_len;
        session.codex.transcript.value = session.published;
        session.codex.resume_target = conversation;
    }

    session.commands = .init(&session.command_storage);
    session.changes = .init(&session.change_storage);
    session.worker = try io.concurrent(run, .{ session, io });
    return session;
}

/// Enqueues a copied UTF-8 prompt without allocation or waiting for the provider.
/// Example: `if (!session.submit(io, message)) return error.AgentBusy;`
pub fn submit(session: *Session, io: std.Io, request: core.AgentSubmission) bool {
    const text = request.text;
    if ((text.len == 0 and request.images.count == 0) or text.len > core.agent_thread.max_prompt_bytes or !std.unicode.utf8ValidateSlice(text)) {
        return false;
    }

    const images = core.AgentImages.copy(request.images) catch return false;
    if (!session.ready.load(.acquire) or session.prompt_pending.swap(true, .acq_rel)) {
        return false;
    }

    var prompt: Prompt = .{ .len = @intCast(text.len), .options = request.options, .images = images };
    @memcpy(prompt.bytes[0..text.len], text);
    if (!session.mutex.tryLock()) {
        session.prompt_pending.store(false, .release);
        return false;
    }

    defer session.mutex.unlock(io);
    if (session.published.status != .ready or session.resume_queued or session.reserved.id_len != 0 or !session.published.accepts(request.options)) {
        session.prompt_pending.store(false, .release);
        return false;
    }

    session.accepted_prompt = prompt;
    if (session.enqueue(io, .{ .prompt = prompt })) {
        return true;
    }

    session.accepted_prompt = null;
    session.prompt_pending.store(false, .release);
    return false;
}

/// Reserves an unused pane before queueing a copied catalog selection.
/// Example: `if (!session.resumeConversation(io, entry)) return error.AgentBusy;`
pub fn resumeConversation(session: *Session, io: std.Io, entry: core.RecentConversation) bool {
    if (!session.ready.load(.acquire) or session.prompt_pending.load(.acquire) or !session.mutex.tryLock()) {
        return false;
    }

    defer session.mutex.unlock(io);
    if (!session.published.canResume() or session.resume_queued or session.reserved.id_len != 0) {
        return false;
    }

    session.reserved = entry;
    session.resume_queued = true;
    session.ready.store(false, .release);
    if (session.enqueue(io, .{ .resume_conversation = entry })) {
        return true;
    }

    session.reserved = .{};
    session.resume_queued = false;
    session.ready.store(true, .release);
    return false;
}

/// Includes an admitted resume before its first provider snapshot arrives.
/// Example: `if (try session.claims(io, id)) return error.ConversationAlreadyOpen;`
pub fn claims(session: *Session, io: std.Io, id: []const u8) !bool {
    if (!session.mutex.tryLock()) {
        return error.AgentBusy;
    }

    defer session.mutex.unlock(io);
    return std.mem.eql(u8, id, session.reserved.idSlice()) or std.mem.eql(u8, id, session.published.threadId());
}

/// Example: `_ = session.interrupt(io);`
pub fn interrupt(session: *Session, io: std.Io) bool {
    return session.enqueue(io, .interrupt);
}

/// Only a user decision naming a pending approval may authorize work.
/// Example: `_ = session.approve(io, .{ .id = approval.id, .accepted = true });`
pub fn approve(session: *Session, io: std.Io, decision: core.AgentApprovalDecision) bool {
    return session.enqueue(io, .{ .approval = decision });
}

/// Coalesces intermediate revisions; the receiver always fetches a full snapshot.
/// Example: `try session.waitForChange(io);`
pub fn waitForChange(session: *Session, io: std.Io) !void {
    _ = try session.changes.getOne(io);
}

/// Retains immutable configuration without allocating in the request path.
/// Example: `const options = session.retainHistoryOptions(); defer options.release();`.
pub fn retainHistoryOptions(session: *const Session) *HistoryOptions {
    return session.history_options.retain();
}

/// Copies conversation and owned metadata from the same publication. A busy
/// publisher wakes the reader again without blocking the runtime loop.
/// Example: `if (session.snapshot(io, &value)) |metadata| project(value, metadata);`
pub fn snapshot(session: *Session, io: std.Io, output: *core.AgentThreadSnapshot) ?ThreadMetadata {
    if (!session.mutex.tryLock()) {
        return null;
    }

    defer session.mutex.unlock(io);
    output.* = session.published;
    return session.published_metadata;
}

/// Copies only the durable identity, including a restore still awaiting the provider.
/// A busy publisher defers the checkpoint instead of dropping its conversation.
/// Example: `const conversation = try session.checkpoint(io);`
pub fn checkpoint(session: *Session, io: std.Io) !?core.RecentConversation {
    if (!session.mutex.tryLock()) {
        return error.AgentBusy;
    }

    defer session.mutex.unlock(io);
    if (session.published.thread_id_len == 0) {
        return null;
    }

    return try core.RecentConversation.init(session.published.threadId(), session.published_metadata.nameSlice() orelse "");
}

/// Signals shutdown without waiting for provider I/O or process cleanup.
/// Example: `session.stop(io);`
pub fn stop(session: *Session, io: std.Io) void {
    session.stopping.store(true, .release);
    session.commands.close(io);
    session.changes.close(io);
}

/// Joins the worker from the observation receiver after stop closed its queue.
/// Example: `session.waitStopped(io);`
pub fn waitStopped(session: *Session, io: std.Io) void {
    if (session.worker) |*worker| {
        worker.await(io);
        session.worker = null;
    }
}

/// Joins the owner after external change receivers have stopped, then frees state.
/// Example: `session.close(io);`
pub fn close(session: *Session, io: std.Io) void {
    session.stop(io);
    session.waitStopped(io);

    const gpa = session.gpa;
    session.history_options.release();
    gpa.destroy(session);
}

fn enqueue(session: *Session, io: std.Io, command: Command) bool {
    if (session.stopping.load(.acquire)) {
        return false;
    }

    return (session.commands.put(io, &.{command}, 0) catch 0) == 1;
}

fn receiveCommand(session: *Session, io: std.Io) anyerror!Command {
    return session.commands.getOne(io);
}

fn publish(session: *Session, io: std.Io) void {
    session.codex.transcript.value.revision += 1;
    session.mutex.lockUncancelable(io);
    session.published = session.codex.transcript.value;
    session.published_metadata = session.codex.metadata;
    if (!session.resume_queued and session.codex.pending_resume_request == null) {
        session.reserved = .{};
    }
    session.ready.store(session.codex.transcript.value.status == .ready and !session.resume_queued, .release);
    session.mutex.unlock(io);
    _ = session.changes.put(io, &.{1}, 0) catch 0;
}

fn run(session: *Session, io: std.Io) void {
    const path = core.enter(.observation);
    defer path.restore();
    session.runProvider(io) catch |err| {
        session.commands.close(io);
        session.ready.store(false, .release);
        if (!session.stopping.load(.acquire)) {
            session.recoverPrompt(io);
            var buffer: [256]u8 = undefined;
            const message = std.fmt.bufPrint(&buffer, "Codex app-server stopped: {s}.", .{@errorName(err)}) catch "Codex app-server stopped.";
            session.codex.fail(message);
            session.publish(io);
        }
    };
    session.commands.close(io);
}

fn runProvider(session: *Session, io: std.Io) !void {
    var child = try std.process.spawn(io, .{
        .argv = session.history_options.arguments,
        .cwd = .{ .path = session.history_options.cwd },
        .environ_map = &session.history_options.environment,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = 0,
    });
    defer {
        if (child.id) |id| {
            std.posix.kill(-id, .KILL) catch {};
        }

        child.kill(io);
    }

    session.stream = .{ .file = child.stdout.?, .output_frame = &session.output_frame };
    try write(io, child.stdin.?, try session.codex.initialize());
    var event_storage: [5]protocol.Event = undefined;
    var select = std.Io.Select(protocol.Event).init(io, &event_storage);
    defer select.cancelDiscard();
    try select.concurrent(.line, Stream.next, .{ &session.stream, io });
    try select.concurrent(.command, receiveCommand, .{ session, io });
    try select.concurrent(.deadline, startupDeadline, .{ io, session.startup_timeout_ms });

    var resume_deadline_pending = false;
    var command_deadline_pending = false;
    var command_started_ms: i64 = 0;
    while (!session.stopping.load(.acquire)) {
        const event = try select.await();
        switch (event) {
            .line => |result| {
                const line = try result;
                var allocator: std.heap.FixedBufferAllocator = .init(&session.json_storage);
                const parsed = try std.json.parseFromSlice(std.json.Value, allocator.allocator(), line, .{ .max_value_len = protocol.max_line_bytes });
                defer parsed.deinit();
                if (try session.codex.receive(.{ .value = parsed.value, .truncated = session.stream.truncated })) |reply| {
                    try write(io, child.stdin.?, reply);
                }

                session.publish(io);
                try select.concurrent(.line, Stream.next, .{ &session.stream, io });
            },
            .command => |result| {
                const command = result catch |err| {
                    if (err == error.Closed) {
                        return;
                    }

                    return err;
                };
                const line = try session.codex.command(command);
                if (command == .prompt and session.codex.command_request != null) {
                    command_started_ms = @intCast(std.Io.Timestamp.now(io, .awake).toMilliseconds());
                    if (!command_deadline_pending) {
                        try select.concurrent(.command_deadline, startupDeadline, .{ io, session.startup_timeout_ms });
                        command_deadline_pending = true;
                    }
                }
                if (command == .resume_conversation) {
                    session.mutex.lockUncancelable(io);
                    session.resume_queued = false;
                    session.mutex.unlock(io);
                    if (!resume_deadline_pending) {
                        try select.concurrent(.resume_deadline, startupDeadline, .{ io, session.startup_timeout_ms });
                        resume_deadline_pending = true;
                    }
                }
                if (command == .prompt) {
                    session.mutex.lockUncancelable(io);
                    session.accepted_prompt = null;
                    session.mutex.unlock(io);
                }

                if (line) |bytes| {
                    try write(io, child.stdin.?, bytes);
                }

                session.publish(io);
                if (command == .prompt) {
                    session.prompt_pending.store(false, .release);
                }

                try select.concurrent(.command, receiveCommand, .{ session, io });
            },
            .command_deadline => |result| {
                try result;
                command_deadline_pending = false;
                if (session.codex.command_request != null) {
                    const elapsed = std.Io.Timestamp.now(io, .awake).toMilliseconds() - command_started_ms;
                    if (elapsed >= session.startup_timeout_ms) {
                        return error.ProviderCommandTimeout;
                    }

                    try select.concurrent(.command_deadline, startupDeadline, .{ io, @as(u32, @intCast(session.startup_timeout_ms - elapsed)) });
                    command_deadline_pending = true;
                }
            },
            .resume_deadline => |result| {
                try result;
                resume_deadline_pending = false;
                try session.codex.expireResume();
            },
            .deadline => |result| {
                try result;
                if (session.codex.skills.value.phase == .loading) {
                    session.codex.skills_request = null;
                    session.codex.skills.value.phase = .failed;
                    session.codex.skills.value.revision +%= 1;
                    session.codex.transcript.value.skills = session.codex.skills.value;
                    session.publish(io);
                }
                if (session.codex.transcript.value.recent.phase == .loading) {
                    session.codex.transcript.value.recent.phase = .failed;
                    session.publish(io);
                }
                if (session.codex.thread_id_len == 0 or !session.codex.catalog_loaded) {
                    return error.ProviderStartupTimeout;
                }
            },
        }
    }
}

fn recoverPrompt(session: *Session, io: std.Io) void {
    session.mutex.lockUncancelable(io);
    const prompt = session.accepted_prompt;
    session.accepted_prompt = null;
    session.mutex.unlock(io);
    if (prompt) |value| {
        var preview: [core.agent_thread.max_prompt_bytes + 64]u8 = undefined;
        session.codex.transcript.update(.{ .role = .user, .text = value.preview(&preview), .complete = true });
    }
}

fn startupDeadline(io: std.Io, timeout_ms: u32) anyerror!void {
    return std.Io.sleep(io, .fromMilliseconds(timeout_ms), .awake);
}

fn write(io: std.Io, file: std.Io.File, line: []const u8) !void {
    var event_storage: [2]protocol.WriteEvent = undefined;
    var select = std.Io.Select(protocol.WriteEvent).init(io, &event_storage);
    defer select.cancelDiscard();
    try select.concurrent(.written, writeAll, .{ io, file, line });
    try select.concurrent(.deadline, startupDeadline, .{ io, @as(u32, 5000) });
    switch (try select.await()) {
        .written => |result| try result,
        .deadline => |result| {
            try result;
            return error.ProviderWriteTimeout;
        },
    }
}

fn writeAll(io: std.Io, file: std.Io.File, line: []const u8) anyerror!void {
    return file.writeStreamingAll(io, line);
}

test {
    _ = @import("Transcript.zig");
    _ = @import("codex_test.zig");
    _ = @import("adversarial_test.zig");
    _ = @import("session_test.zig");
    _ = @import("ProviderHistory.zig");
}
