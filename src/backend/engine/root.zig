//! A long-lived headless agent engine owned by the runtime.
//!
//! The engine is Pi in RPC mode, or any command that speaks the same JSONL
//! contract. It answers bounded prompts with bounded text on the observation
//! path: requests queue behind one actor, the child starts on the first
//! prompt, and it is killed after an idle interval or on any protocol failure
//! so the next prompt starts a fresh process. Nothing here touches the
//! interactive path, and prompts never enter process arguments.

const std = @import("std");

pub const rpc = @import("rpc.zig");

const Io = std.Io;

pub const max_prompt_bytes = 8 * 1024;
pub const max_reply_bytes = 4 * 1024;
pub const max_pending_requests = 8;

pub const Options = struct {
    arguments: []const []const u8,
    /// Deadline for one prompt, from the command write to the assistant text.
    timeout_ms: u32,
    /// Idle interval after which the child is killed. The runtime asks for
    /// the check on its own cadence; the engine never runs a timer.
    idle_timeout_ms: u32,
};

/// Identifies who asked, so the runtime routes a reply without keeping
/// per-request state.
pub const Purpose = union(enum) {
    title: Title,

    pub const Title = struct {
        pane_id: u64,
        pane_generation: u64,
        session_id: [16]u8,
    };
};

pub const Prompt = struct {
    purpose: Purpose,
    bytes: [max_prompt_bytes]u8 = undefined,
    len: u16 = 0,

    /// Builds a bounded prompt.
    ///
    /// ```zig
    /// const prompt = try Prompt.init(.{ .title = title }, text);
    /// ```
    pub fn init(purpose: Purpose, text: []const u8) !Prompt {
        if (text.len == 0 or text.len > max_prompt_bytes) {
            return error.InvalidPrompt;
        }

        var prompt: Prompt = .{ .purpose = purpose, .len = @intCast(text.len) };
        @memcpy(prompt.bytes[0..text.len], text);
        return prompt;
    }

    pub fn slice(prompt: *const Prompt) []const u8 {
        return prompt.bytes[0..prompt.len];
    }
};

pub const Request = union(enum) {
    prompt: Prompt,
    idle_check,
};

pub const Status = enum {
    success,
    /// The command could not start at all.
    unavailable,
    timeout,
    /// The engine answered, but not with usable text.
    invalid_output,
    failed,
};

pub const Response = struct {
    purpose: Purpose,
    status: Status,
    text: [max_reply_bytes]u8 = undefined,
    text_len: u16 = 0,

    pub fn textSlice(response: *const Response) []const u8 {
        return response.text[0..response.text_len];
    }
};

/// Bounded request and response rings around one sequential engine actor.
/// The service must live at a stable address for as long as `run` executes.
pub const Service = struct {
    gpa: std.mem.Allocator,
    options: Options,
    requests: Io.Queue(Request),
    responses: Io.Queue(Response),
    request_storage: []Request,
    response_storage: []Response,
    session: ?*Session = null,
    child_alive: std.atomic.Value(bool) = .init(false),
    idle_check_pending: std.atomic.Value(bool) = .init(false),

    /// Allocates the rings. No child is started.
    ///
    /// ```zig
    /// var service = try Service.init(gpa, options);
    /// defer service.deinit(io);
    /// ```
    pub fn init(gpa: std.mem.Allocator, options: Options) !Service {
        const request_storage = try gpa.alloc(Request, max_pending_requests);
        errdefer gpa.free(request_storage);
        const response_storage = try gpa.alloc(Response, max_pending_requests);
        errdefer gpa.free(response_storage);

        return .{
            .gpa = gpa,
            .options = options,
            .requests = .init(request_storage),
            .responses = .init(response_storage),
            .request_storage = request_storage,
            .response_storage = response_storage,
        };
    }

    /// Closes both rings so `run` returns and blocked receivers fail.
    ///
    /// ```zig
    /// service.stop(io);
    /// ```
    pub fn stop(service: *Service, io: Io) void {
        service.requests.close(io);
        service.responses.close(io);
    }

    /// Kills a live child and frees the rings. `run` must have returned.
    ///
    /// ```zig
    /// service.deinit(io);
    /// ```
    pub fn deinit(service: *Service, io: Io) void {
        service.responses.close(io);
        service.closeSession(io);
        service.gpa.free(service.request_storage);
        service.gpa.free(service.response_storage);
    }

    /// Queues one request without blocking. Returns false when the ring is
    /// full or closed; the caller decides whether that is a failure.
    ///
    /// ```zig
    /// if (!service.submit(io, .{ .prompt = prompt })) return error.EngineBusy;
    /// ```
    pub fn submit(service: *Service, io: Io, request: Request) bool {
        const queued = service.requests.put(io, &.{request}, 0) catch return false;
        return queued == 1;
    }

    /// Asks the actor to kill an idle child. Cheap to call on every
    /// maintenance tick: it queues nothing while no child is alive or while
    /// a check is already pending.
    ///
    /// ```zig
    /// service.requestIdleCheck(io);
    /// ```
    pub fn requestIdleCheck(service: *Service, io: Io) void {
        if (!service.child_alive.load(.acquire)) {
            return;
        }

        if (service.idle_check_pending.swap(true, .acq_rel)) {
            return;
        }

        if (!service.submit(io, .idle_check)) {
            service.idle_check_pending.store(false, .release);
        }
    }

    /// Waits for the next reply. Fails once the service is stopped.
    ///
    /// ```zig
    /// const response = try service.receiveResponse(io);
    /// ```
    pub fn receiveResponse(service: *Service, io: Io) anyerror!Response {
        return service.responses.getOne(io);
    }

    /// Serves requests in order until `stop` closes the ring.
    ///
    /// ```zig
    /// var worker = try io.concurrent(Service.run, .{ &service, io });
    /// ```
    pub fn run(service: *Service, io: Io) anyerror!void {
        while (true) {
            const request = service.requests.getOne(io) catch return;
            service.handle(io, request);
        }
    }

    /// Applies one request on the actor. Public so tests drive the actor
    /// synchronously; `run` is this in a loop.
    ///
    /// ```zig
    /// service.handle(io, .idle_check);
    /// ```
    pub fn handle(service: *Service, io: Io, request: Request) void {
        switch (request) {
            .idle_check => {
                service.idle_check_pending.store(false, .release);
                const session = service.session orelse return;
                if (nowMs(io) - session.last_used_ms >= service.options.idle_timeout_ms) {
                    service.closeSession(io);
                }
            },
            .prompt => |*prompt| {
                const response = service.answer(io, prompt);
                service.responses.putOne(io, response) catch {};
            },
        }
    }

    fn answer(service: *Service, io: Io, prompt: *const Prompt) Response {
        var response: Response = .{ .purpose = prompt.purpose, .status = .failed };
        const session = service.ensureSession(io) catch |err| {
            response.status = if (err == error.FileNotFound) .unavailable else .failed;
            return response;
        };

        response.status = session.ask(io, service.gpa, prompt.slice(), service.options.timeout_ms, &response);
        session.last_used_ms = nowMs(io);

        switch (response.status) {
            .success, .invalid_output => {},
            .unavailable, .timeout, .failed => service.closeSession(io),
        }

        return response;
    }

    fn ensureSession(service: *Service, io: Io) !*Session {
        if (service.session) |session| {
            return session;
        }

        const session = try Session.open(io, service.gpa, service.options.arguments);
        service.session = session;
        service.child_alive.store(true, .release);
        return session;
    }

    fn closeSession(service: *Service, io: Io) void {
        const session = service.session orelse return;
        service.session = null;
        service.child_alive.store(false, .release);
        session.close(io, service.gpa);
    }
};

const Next = union(enum) {
    record: rpc.Record,
    /// A record above the line bound was dropped whole.
    discarded,
    /// The child closed its output.
    closed,
};

const NextError = error{ Timeout, ReadFailed };

/// One child process and the reader that follows its record stream.
const Session = struct {
    child: std.process.Child,
    streams: Io.File.MultiReader.Buffer(1) = undefined,
    reader: Io.File.MultiReader = undefined,
    line_buffer: [rpc.max_line_bytes]u8 = undefined,
    last_used_ms: i64,
    discarding: bool = false,

    fn open(io: Io, gpa: std.mem.Allocator, arguments: []const []const u8) !*Session {
        if (arguments.len == 0) {
            return error.FileNotFound;
        }

        const session = try gpa.create(Session);
        errdefer gpa.destroy(session);
        session.* = .{ .child = undefined, .last_used_ms = nowMs(io) };
        session.child = try std.process.spawn(io, .{
            .argv = arguments,
            // Keep the engine away from any repository: context files and
            // trust decisions are explicit argv from Lua, never the cwd.
            .cwd = .{ .path = "/" },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        session.reader.init(gpa, io, session.streams.toStreams(), &.{session.child.stdout.?});
        return session;
    }

    fn close(session: *Session, io: Io, gpa: std.mem.Allocator) void {
        session.reader.deinit();
        session.child.kill(io);
        gpa.destroy(session);
    }

    /// Sends one prompt and waits for the settled assistant text within the
    /// deadline. The text is copied into `response` on success.
    fn ask(session: *Session, io: Io, gpa: std.mem.Allocator, prompt: []const u8, timeout_ms: u32, response: *Response) Status {
        const timeout: Io.Timeout = .{ .deadline = .fromNow(io, .{
            .clock = .awake,
            .raw = .fromMilliseconds(timeout_ms),
        }) };

        const prompt_line = rpc.encodePrompt(&session.line_buffer, prompt) catch return .failed;
        session.writeLine(io, prompt_line) catch return .failed;

        while (true) {
            var step = session.next(io, gpa, timeout) catch |err| return statusFromError(err);
            switch (step) {
                .closed => return .failed,
                .discarded => continue,
                .record => |*record| {
                    defer record.deinit();
                    switch (record.kind) {
                        .prompt_rejected => return .failed,
                        .agent_settled => break,
                        else => {},
                    }
                },
            }
        }

        const query_line = rpc.encodeCommand(&session.line_buffer, "get_last_assistant_text") catch return .failed;
        session.writeLine(io, query_line) catch return .failed;

        while (true) {
            var step = session.next(io, gpa, timeout) catch |err| return statusFromError(err);
            switch (step) {
                .closed => return .failed,
                .discarded => return .invalid_output,
                .record => |*record| {
                    defer record.deinit();
                    if (record.kind != .last_text) {
                        continue;
                    }

                    const text = record.text() orelse return .invalid_output;
                    if (text.len == 0 or text.len > max_reply_bytes) {
                        return .invalid_output;
                    }

                    @memcpy(response.text[0..text.len], text);
                    response.text_len = @intCast(text.len);
                    return .success;
                },
            }
        }
    }

    fn writeLine(session: *Session, io: Io, line: []const u8) !void {
        const stdin = session.child.stdin orelse return error.WriteFailed;
        stdin.writeStreamingAll(io, line) catch return error.WriteFailed;
    }

    /// Yields the next parseable record, dropping unparseable and oversized
    /// lines. Waits at most until `timeout`.
    fn next(session: *Session, io: Io, gpa: std.mem.Allocator, timeout: Io.Timeout) NextError!Next {
        _ = io;
        const reader = session.reader.reader(0);

        while (true) {
            const buffered = reader.buffered();
            if (std.mem.indexOfScalar(u8, buffered, '\n')) |newline| {
                var line = buffered[0..newline];
                if (line.len != 0 and line[line.len - 1] == '\r') {
                    line = line[0 .. line.len - 1];
                }

                const was_discarding = session.discarding;
                session.discarding = false;
                if (was_discarding) {
                    reader.toss(newline + 1);
                    return .discarded;
                }

                const record = rpc.parse(gpa, line);
                reader.toss(newline + 1);
                if (record) |value| {
                    return .{ .record = value };
                }

                continue;
            }

            if (buffered.len > rpc.max_line_bytes) {
                reader.toss(buffered.len);
                session.discarding = true;
            }

            session.reader.fill(1, timeout) catch |err| switch (err) {
                error.EndOfStream => return .closed,
                error.Timeout => return error.Timeout,
                else => return error.ReadFailed,
            };
        }
    }
};

fn statusFromError(err: NextError) Status {
    return switch (err) {
        error.Timeout => .timeout,
        error.ReadFailed => .failed,
    };
}

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toMilliseconds();
}

const test_purpose: Purpose = .{ .title = .{ .pane_id = 7, .pane_generation = 2, .session_id = .{3} ** 16 } };

const fake_engine =
    \\while IFS= read -r line; do
    \\  case "$line" in
    \\    *'"type":"prompt"'*) printf '%s\n' '{"type":"response","command":"prompt","success":true}' '{"type":"agent_start"}' 'not json' '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"x"}}' '{"type":"agent_settled"}' ;;
    \\    *get_last_assistant_text*) printf '%s\n' '{"type":"agent_end","messages":[]}' '{"type":"response","command":"get_last_assistant_text","success":true,"data":{"text":"Improve agent sidebar"}}' ;;
    \\  esac
    \\done
;

/// `arguments` must outlive the service, so callers declare the argv in
/// their own frame.
fn testService(arguments: []const []const u8, timeout_ms: u32, idle_timeout_ms: u32) !Service {
    return Service.init(std.testing.allocator, .{
        .arguments = arguments,
        .timeout_ms = timeout_ms,
        .idle_timeout_ms = idle_timeout_ms,
    });
}

test "the actor answers prompts over one child and reuses it" {
    const io = std.testing.io;
    var service = try testService(&.{ "/bin/sh", "-c", fake_engine }, 5000, 60_000);
    defer service.deinit(io);

    const prompt = try Prompt.init(test_purpose, "Create a title");
    service.handle(io, .{ .prompt = prompt });
    var response = try service.receiveResponse(io);
    try std.testing.expectEqual(Status.success, response.status);
    try std.testing.expectEqualStrings("Improve agent sidebar", response.textSlice());
    try std.testing.expectEqual(@as(u64, 7), response.purpose.title.pane_id);
    try std.testing.expect(service.child_alive.load(.acquire));
    const first = service.session.?;

    service.handle(io, .{ .prompt = prompt });
    response = try service.receiveResponse(io);
    try std.testing.expectEqual(Status.success, response.status);
    try std.testing.expect(service.session.? == first);

    // Still fresh: the idle check keeps the child.
    service.handle(io, .idle_check);
    try std.testing.expect(service.session != null);
}

test "an idle check kills a child past the idle interval" {
    const io = std.testing.io;
    var service = try testService(&.{ "/bin/sh", "-c", fake_engine }, 5000, 0);
    defer service.deinit(io);

    service.handle(io, .{ .prompt = try Prompt.init(test_purpose, "Create a title") });
    _ = try service.receiveResponse(io);
    try std.testing.expect(service.child_alive.load(.acquire));

    service.requestIdleCheck(io);
    try std.testing.expect(service.idle_check_pending.load(.acquire));
    service.handle(io, try service.requests.getOne(io));
    try std.testing.expect(service.session == null);
    try std.testing.expect(!service.child_alive.load(.acquire));
    try std.testing.expect(!service.idle_check_pending.load(.acquire));

    // Nothing alive: the check queues nothing.
    service.requestIdleCheck(io);
    try std.testing.expect(!service.idle_check_pending.load(.acquire));
}

test "protocol failures report a status and discard the child" {
    const io = std.testing.io;
    const prompt = try Prompt.init(test_purpose, "Create a title");

    var silent = try testService(&.{ "/bin/sh", "-c", "read -r line; printf '%s\\n' '{\"type\":\"response\",\"command\":\"prompt\",\"success\":true}'; sleep 5" }, 100, 60_000);
    defer silent.deinit(io);
    silent.handle(io, .{ .prompt = prompt });
    try std.testing.expectEqual(Status.timeout, (try silent.receiveResponse(io)).status);
    try std.testing.expect(silent.session == null);

    var rejecting = try testService(&.{ "/bin/sh", "-c", "read -r line; printf '%s\\n' '{\"type\":\"response\",\"command\":\"prompt\",\"success\":false}'; sleep 5" }, 1000, 60_000);
    defer rejecting.deinit(io);
    rejecting.handle(io, .{ .prompt = prompt });
    try std.testing.expectEqual(Status.failed, (try rejecting.receiveResponse(io)).status);

    var dying = try testService(&.{ "/bin/sh", "-c", "exit 0" }, 1000, 60_000);
    defer dying.deinit(io);
    dying.handle(io, .{ .prompt = prompt });
    try std.testing.expectEqual(Status.failed, (try dying.receiveResponse(io)).status);
    try std.testing.expect(!dying.child_alive.load(.acquire));

    var empty = try testService(&.{ "/bin/sh", "-c", "read -r line; printf '%s\\n' '{\"type\":\"response\",\"command\":\"prompt\",\"success\":true}' '{\"type\":\"agent_settled\"}'; read -r line; printf '%s\\n' '{\"type\":\"response\",\"command\":\"get_last_assistant_text\",\"success\":true,\"data\":{\"text\":null}}'; sleep 5" }, 1000, 60_000);
    defer empty.deinit(io);
    empty.handle(io, .{ .prompt = prompt });
    try std.testing.expectEqual(Status.invalid_output, (try empty.receiveResponse(io)).status);
    try std.testing.expect(empty.session != null);

    var missing = try Service.init(std.testing.allocator, .{
        .arguments = &.{"/definitely/not/a/telar-engine"},
        .timeout_ms = 1000,
        .idle_timeout_ms = 60_000,
    });
    defer missing.deinit(io);
    missing.handle(io, .{ .prompt = prompt });
    try std.testing.expectEqual(Status.unavailable, (try missing.receiveResponse(io)).status);
}

test "oversized records are dropped and an oversized reply is invalid" {
    const io = std.testing.io;
    var service = try testService(&.{
        "/bin/sh", "-c",
        \\read -r line
        \\printf '%s\n' '{"type":"response","command":"prompt","success":true}'
        \\head -c 70000 /dev/zero | tr '\0' 'a'; printf '\n'
        \\printf '%s\n' '{"type":"agent_settled"}'
        \\read -r line
        \\printf '{"type":"response","command":"get_last_assistant_text","success":true,"data":{"text":"'
        \\head -c 70000 /dev/zero | tr '\0' 'b'; printf '"}}\n'
        \\sleep 5
    }, 5000, 60_000);
    defer service.deinit(io);

    service.handle(io, .{ .prompt = try Prompt.init(test_purpose, "Create a title") });
    try std.testing.expectEqual(Status.invalid_output, (try service.receiveResponse(io)).status);
}

test "the ring refuses requests beyond its capacity and the loop drains it" {
    const io = std.testing.io;
    var service = try testService(&.{ "/bin/sh", "-c", fake_engine }, 5000, 60_000);
    defer service.deinit(io);

    const prompt = try Prompt.init(test_purpose, "Create a title");
    for (0..max_pending_requests) |_| try std.testing.expect(service.submit(io, .{ .prompt = prompt }));
    try std.testing.expect(!service.submit(io, .{ .prompt = prompt }));

    var worker = try io.concurrent(Service.run, .{ &service, io });
    for (0..max_pending_requests) |_| {
        try std.testing.expectEqual(Status.success, (try service.receiveResponse(io)).status);
    }

    service.stop(io);
    _ = worker.await(io) catch {};
    try std.testing.expect(!service.submit(io, .idle_check));
    try std.testing.expectError(error.Closed, service.receiveResponse(io));
    try std.testing.expectError(error.InvalidPrompt, Prompt.init(test_purpose, ""));
}
