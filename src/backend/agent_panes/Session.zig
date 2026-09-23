const command_module = @import("command.zig");
const ReviewService = @import("../change_review/Service.zig");
const ReviewContext = @import("../change_review/Context.zig");
const ItemNormalizer = @import("ItemNormalizer.zig");
const std = @import("std");
const core = @import("telar-core");
const Options = @import("Options.zig");
const Codex = @import("Codex.zig");
const Stream = @import("Stream.zig");
const protocol = @import("protocol.zig");
const Prompt = @import("Prompt.zig");
const ThreadMetadata = @import("ThreadMetadata.zig");
const HistoryOptions = @import("HistoryOptions.zig");
const OutputFrame = @import("OutputFrame.zig");
const Session = @This();

gpa: std.mem.Allocator,
review_service: ?*ReviewService = null,
history_options: *HistoryOptions,
startup_timeout_ms: u32,
worker: ?std.Io.Future(void) = null,
commands: std.Io.Queue(command_module.Command) = undefined,
command_storage: [protocol.queue_depth]command_module.Command = undefined,
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
output_frame: OutputFrame = .{},
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
        .review_service = options.review_service,
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
pub fn submit(self: *Session, io: std.Io, request: core.AgentSubmission) bool {
    const text = request.text;
    if ((text.len == 0 and request.images.count == 0) or text.len > core.agent_thread.max_prompt_bytes or !std.unicode.utf8ValidateSlice(text)) {
        return false;
    }

    const images = core.AgentImages.copy(request.images) catch return false;
    if (!self.ready.load(.acquire) or self.prompt_pending.swap(true, .acq_rel)) {
        return false;
    }

    var prompt: Prompt = .{ .len = @intCast(text.len), .options = request.options, .images = images };
    @memcpy(prompt.bytes[0..text.len], text);
    if (!self.mutex.tryLock()) {
        self.prompt_pending.store(false, .release);
        return false;
    }

    defer self.mutex.unlock(io);
    if (self.published.status != .ready or self.resume_queued or self.reserved.id_len != 0 or !self.published.accepts(request.options)) {
        self.prompt_pending.store(false, .release);
        return false;
    }

    self.accepted_prompt = prompt;
    if (self.enqueue(io, .{ .prompt = prompt })) {
        return true;
    }

    self.accepted_prompt = null;
    self.prompt_pending.store(false, .release);
    return false;
}

/// Reserves an unused pane before queueing a copied catalog selection.
/// Example: `if (!session.resumeConversation(io, entry)) return error.AgentBusy;`
pub fn resumeConversation(self: *Session, io: std.Io, entry: core.RecentConversation) bool {
    if (!self.ready.load(.acquire) or self.prompt_pending.load(.acquire) or !self.mutex.tryLock()) {
        return false;
    }

    defer self.mutex.unlock(io);
    if (!self.published.canResume() or self.resume_queued or self.reserved.id_len != 0) {
        return false;
    }

    self.reserved = entry;
    self.resume_queued = true;
    self.ready.store(false, .release);
    if (self.enqueue(io, .{ .resume_conversation = entry })) {
        return true;
    }

    self.reserved = .{};
    self.resume_queued = false;
    self.ready.store(true, .release);
    return false;
}

/// Includes an admitted resume before its first provider snapshot arrives.
/// Example: `if (try session.claims(io, id)) return error.ConversationAlreadyOpen;`
pub fn claims(self: *Session, io: std.Io, id: []const u8) !bool {
    if (!self.mutex.tryLock()) {
        return error.AgentBusy;
    }

    defer self.mutex.unlock(io);
    return std.mem.eql(u8, id, self.reserved.idSlice()) or std.mem.eql(u8, id, self.published.threadId());
}

/// Example: `_ = session.interrupt(io);`
pub fn interrupt(self: *Session, io: std.Io) bool {
    return self.enqueue(io, .interrupt);
}

/// Only a user decision naming a pending approval may authorize work.
/// Example: `_ = session.approve(io, .{ .id = approval.id, .accepted = true });`
pub fn approve(self: *Session, io: std.Io, decision: core.AgentApprovalDecision) bool {
    return self.enqueue(io, .{ .approval = decision });
}

/// Coalesces intermediate revisions; the receiver always fetches a full snapshot.
/// Example: `try session.waitForChange(io);`
pub fn waitForChange(self: *Session, io: std.Io) !void {
    _ = try self.changes.getOne(io);
}

/// Retains immutable configuration without allocating in the request path.
/// Example: `const options = session.retainHistoryOptions(); defer options.release();`.
pub fn retainHistoryOptions(self: *const Session) *HistoryOptions {
    return self.history_options.retain();
}

/// Copies conversation and owned metadata from the same publication. A busy
/// publisher wakes the reader again without blocking the runtime loop.
/// Example: `if (session.snapshot(io, &value)) |metadata| project(value, metadata);`
pub fn snapshot(self: *Session, io: std.Io, output: *core.AgentThreadSnapshot) ?ThreadMetadata {
    if (!self.mutex.tryLock()) {
        return null;
    }

    defer self.mutex.unlock(io);
    output.* = self.published;
    return self.published_metadata;
}

/// Copies only the durable identity, including a restore still awaiting the provider.
/// A busy publisher defers the checkpoint instead of dropping its conversation.
/// Example: `const conversation = try session.checkpoint(io);`
pub fn checkpoint(self: *Session, io: std.Io) !?core.RecentConversation {
    if (!self.mutex.tryLock()) {
        return error.AgentBusy;
    }

    defer self.mutex.unlock(io);
    if (self.published.thread_id_len == 0) {
        return null;
    }

    return try core.RecentConversation.init(self.published.threadId(), self.published_metadata.nameSlice() orelse "");
}

/// Signals shutdown without waiting for provider I/O or process cleanup.
/// Example: `session.stop(io);`
pub fn stop(self: *Session, io: std.Io) void {
    self.stopping.store(true, .release);
    self.commands.close(io);
    self.changes.close(io);
}

/// Joins the worker from the observation receiver after stop closed its queue.
/// Example: `session.waitStopped(io);`
pub fn waitStopped(self: *Session, io: std.Io) void {
    if (self.worker) |*worker| {
        worker.await(io);
        self.worker = null;
    }
}

/// Joins the owner after external change receivers have stopped, then frees state.
/// Example: `session.close(io);`
pub fn close(self: *Session, io: std.Io) void {
    self.stop(io);
    self.waitStopped(io);

    const gpa = self.gpa;
    self.history_options.release();
    gpa.destroy(self);
}

fn enqueue(self: *Session, io: std.Io, command: command_module.Command) bool {
    if (self.stopping.load(.acquire)) {
        return false;
    }

    return (self.commands.put(io, &.{command}, 0) catch 0) == 1;
}

fn receiveCommand(self: *Session, io: std.Io) anyerror!command_module.Command {
    return self.commands.getOne(io);
}

fn publish(self: *Session, io: std.Io) void {
    self.codex.transcript.value.revision += 1;
    self.mutex.lockUncancelable(io);
    self.published = self.codex.transcript.value;
    self.published_metadata = self.codex.metadata;
    if (!self.resume_queued and self.codex.pending_resume_request == null) {
        self.reserved = .{};
    }
    self.ready.store(self.codex.transcript.value.status == .ready and !self.resume_queued, .release);
    self.mutex.unlock(io);
    _ = self.changes.put(io, &.{1}, 0) catch 0;
}

fn run(self: *Session, io: std.Io) void {
    const path = core.enter(.observation);
    defer path.restore();
    self.runProvider(io) catch |err| {
        self.commands.close(io);
        self.ready.store(false, .release);
        if (!self.stopping.load(.acquire)) {
            self.recoverPrompt(io);
            var buffer: [256]u8 = undefined;
            const message = std.fmt.bufPrint(&buffer, "Codex app-server stopped: {s}.", .{@errorName(err)}) catch "Codex app-server stopped.";
            self.codex.fail(message);
            self.publish(io);
        }
    };
    self.commands.close(io);
}

fn runProvider(self: *Session, io: std.Io) !void {
    var child = try std.process.spawn(io, .{
        .argv = self.history_options.arguments,
        .cwd = .{ .path = self.history_options.cwd },
        .environ_map = &self.history_options.environment,
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

    self.stream = .{ .file = child.stdout.?, .output_frame = &self.output_frame };
    try write(io, child.stdin.?, try self.codex.initialize());
    var event_storage: [5]protocol.Event = undefined;
    var select = std.Io.Select(protocol.Event).init(io, &event_storage);
    defer select.cancelDiscard();
    try select.concurrent(.line, Stream.next, .{ &self.stream, io });
    try select.concurrent(.command, receiveCommand, .{ self, io });
    try select.concurrent(.deadline, startupDeadline, .{ io, self.startup_timeout_ms });

    var resume_deadline_pending = false;
    var command_deadline_pending = false;
    var command_started_ms: i64 = 0;
    while (!self.stopping.load(.acquire)) {
        const event = try select.await();
        switch (event) {
            .line => |result| {
                const line = try result;
                var allocator: std.heap.FixedBufferAllocator = .init(&self.json_storage);
                const parsed = try std.json.parseFromSlice(std.json.Value, allocator.allocator(), line, .{ .max_value_len = protocol.max_line_bytes });
                defer parsed.deinit();
                if (try self.codex.receive(.{ .value = parsed.value, .truncated = self.stream.truncated })) |reply| {
                    try write(io, child.stdin.?, reply);
                }

                self.captureReview(io, parsed.value);
                self.publish(io);
                try select.concurrent(.line, Stream.next, .{ &self.stream, io });
            },
            .command => |result| {
                const command = result catch |err| {
                    if (err == error.Closed) {
                        return;
                    }

                    return err;
                };
                const line = try self.codex.command(command);
                if (command == .prompt and self.codex.command_request != null) {
                    command_started_ms = @intCast(std.Io.Timestamp.now(io, .awake).toMilliseconds());
                    if (!command_deadline_pending) {
                        try select.concurrent(.command_deadline, startupDeadline, .{ io, self.startup_timeout_ms });
                        command_deadline_pending = true;
                    }
                }
                if (command == .resume_conversation) {
                    self.mutex.lockUncancelable(io);
                    self.resume_queued = false;
                    self.mutex.unlock(io);
                    if (!resume_deadline_pending) {
                        try select.concurrent(.resume_deadline, startupDeadline, .{ io, self.startup_timeout_ms });
                        resume_deadline_pending = true;
                    }
                }
                if (command == .prompt) {
                    self.mutex.lockUncancelable(io);
                    self.accepted_prompt = null;
                    self.mutex.unlock(io);
                }

                if (line) |bytes| {
                    try write(io, child.stdin.?, bytes);
                }

                self.publish(io);
                if (command == .prompt) {
                    self.prompt_pending.store(false, .release);
                }

                try select.concurrent(.command, receiveCommand, .{ self, io });
            },
            .command_deadline => |result| {
                try result;
                command_deadline_pending = false;
                if (self.codex.command_request != null) {
                    const elapsed = std.Io.Timestamp.now(io, .awake).toMilliseconds() - command_started_ms;
                    if (elapsed >= self.startup_timeout_ms) {
                        return error.ProviderCommandTimeout;
                    }

                    try select.concurrent(.command_deadline, startupDeadline, .{ io, @as(u32, @intCast(self.startup_timeout_ms - elapsed)) });
                    command_deadline_pending = true;
                }
            },
            .resume_deadline => |result| {
                try result;
                resume_deadline_pending = false;
                try self.codex.expireResume();
            },
            .deadline => |result| {
                try result;
                if (self.codex.skills.value.phase == .loading) {
                    self.codex.skills_request = null;
                    self.codex.skills.value.phase = .failed;
                    self.codex.skills.value.revision +%= 1;
                    self.codex.transcript.value.skills = self.codex.skills.value;
                    self.publish(io);
                }
                if (self.codex.transcript.value.recent.phase == .loading) {
                    self.codex.transcript.value.recent.phase = .failed;
                    self.publish(io);
                }
                if (self.codex.thread_id_len == 0 or !self.codex.catalog_loaded) {
                    return error.ProviderStartupTimeout;
                }
            },
        }
    }
}

fn recoverPrompt(self: *Session, io: std.Io) void {
    self.mutex.lockUncancelable(io);
    const prompt = self.accepted_prompt;
    self.accepted_prompt = null;
    self.mutex.unlock(io);
    if (prompt) |value| {
        var preview: [core.agent_thread.max_prompt_bytes + 64]u8 = undefined;
        self.codex.transcript.update(.{ .role = .user, .text = value.preview(&preview), .complete = true });
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

fn captureReview(self: *Session, io: std.Io, value: std.json.Value) void {
    const service = self.review_service orelse return;
    if (!protocol.is(protocol.field(value, "method"), "item/completed") or self.codex.thread_id_len == 0) {
        return;
    }
    const params = protocol.field(value, "params");
    const item = protocol.field(params, "item");
    if (!protocol.is(protocol.field(item, "type"), "fileChange")) {
        return;
    }
    const thread = protocol.string(protocol.field(params, "threadId"));
    if (!std.mem.eql(u8, thread, self.codex.thread_id[0..self.codex.thread_id_len])) {
        return;
    }
    var buffer: [core.change_review.max_patch_bytes]u8 = undefined;
    var normalizer: ItemNormalizer = .{ .body_buffer = &buffer };
    const update = normalizer.item(item, true) orelse return;
    if (update.truncated or self.stream.truncated or update.status != .completed) {
        _ = service.dropped.fetchAdd(1, .monotonic);
        return;
    }
    const context = ReviewContext.init(.{ .id = self.published.pane_id, .generation = self.published.pane_generation }, .codex, thread) catch return;
    const latest = service.recordProvider(io, .{ .context = context, .turn = protocol.string(protocol.field(params, "turnId")), .item = update.id, .patch = update.text }) catch {
        _ = service.dropped.fetchAdd(1, .monotonic);
        return;
    };
    self.codex.metadata.review_latest_edition_id = latest;
}
