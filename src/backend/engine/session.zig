//! One engine child and the dialogue that turns a prompt into its reply.
//!
//! A session spawns the command on `open`, keeps its pipes for as long as
//! the actor reuses it, and is killed on `close`. `ask` speaks the Pi RPC
//! dialogue: send the prompt, wait for the agent to settle, then query the
//! last assistant text. Every failure surfaces as a `Status`; what happens
//! to the child afterwards is the actor's decision, never the session's.

const std = @import("std");
const rpc = @import("rpc.zig");
const types = @import("types.zig");

const Io = std.Io;
const Options = types.Options;
const Response = types.Response;
const Status = types.Status;

const AskError = error{ Timeout, ReadFailed, Closed, Rejected, InvalidOutput, WriteFailed };

pub const Session = struct {
    gpa: std.mem.Allocator,
    timeout_ms: u32,
    child: std.process.Child,
    stream: rpc.Stream = .{},
    line_buffer: [rpc.max_line_bytes]u8 = undefined,
    last_used_ms: i64,

    /// Spawns the engine command. Fails with `error.FileNotFound` when there
    /// is no command to run, so callers can report `unavailable`.
    ///
    /// ```zig
    /// const session = try Session.open(io, gpa, options);
    /// defer session.close(io);
    /// ```
    pub fn open(io: Io, gpa: std.mem.Allocator, options: Options) !*Session {
        if (options.arguments.len == 0) {
            return error.FileNotFound;
        }

        const session = try gpa.create(Session);
        errdefer gpa.destroy(session);
        session.* = .{
            .gpa = gpa,
            .timeout_ms = options.timeout_ms,
            .child = undefined,
            .last_used_ms = nowMs(io),
        };
        session.child = try std.process.spawn(io, .{
            .argv = options.arguments,
            // Keep the engine away from any repository: context files and
            // trust decisions are explicit argv from Lua, never the cwd.
            .cwd = .{ .path = "/" },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        session.stream.init(.{ .allocator = gpa, .io = io, .stdout = session.child.stdout.? });
        return session;
    }

    /// Kills the child and frees the session.
    ///
    /// ```zig
    /// session.close(io);
    /// ```
    pub fn close(session: *Session, io: Io) void {
        session.stream.deinit();
        session.child.kill(io);
        session.gpa.destroy(session);
    }

    /// Sends one prompt and waits for the settled assistant text within the
    /// session deadline. The text is copied into `response` on success.
    ///
    /// ```zig
    /// response.status = session.ask(io, prompt.slice(), &response);
    /// ```
    pub fn ask(session: *Session, io: Io, prompt: []const u8, response: *Response) Status {
        session.exchange(io, prompt, response) catch |err| return switch (err) {
            error.Timeout => .timeout,
            error.InvalidOutput => .invalid_output,
            error.WriteFailed, error.ReadFailed, error.Closed, error.Rejected => .failed,
        };

        return .success;
    }

    /// Records that a prompt was just answered.
    ///
    /// ```zig
    /// session.touch(io);
    /// ```
    pub fn touch(session: *Session, io: Io) void {
        session.last_used_ms = nowMs(io);
    }

    /// Milliseconds since the session was opened or last touched.
    ///
    /// ```zig
    /// if (session.idleMs(io) >= idle_timeout_ms) session.close(io);
    /// ```
    pub fn idleMs(session: *const Session, io: Io) i64 {
        return nowMs(io) - session.last_used_ms;
    }

    fn exchange(session: *Session, io: Io, prompt: []const u8, response: *Response) AskError!void {
        const timeout: Io.Timeout = .{ .deadline = .fromNow(io, .{
            .clock = .awake,
            .raw = .fromMilliseconds(session.timeout_ms),
        }) };

        const prompt_line = try rpc.encodePrompt(&session.line_buffer, prompt);
        try session.writeLine(io, prompt_line);
        try session.awaitSettled(timeout);

        const query_line = try rpc.encodeCommand(&session.line_buffer, "get_last_assistant_text");
        try session.writeLine(io, query_line);
        try session.readLastText(timeout, response);
    }

    fn writeLine(session: *Session, io: Io, line: []const u8) AskError!void {
        const stdin = session.child.stdin orelse return error.WriteFailed;
        stdin.writeStreamingAll(io, line) catch return error.WriteFailed;
    }

    /// Consumes records until the agent settles. A rejected prompt ends the
    /// dialogue; oversized records are ignored.
    fn awaitSettled(session: *Session, timeout: Io.Timeout) AskError!void {
        while (true) {
            var step = try session.stream.next(session.gpa, timeout);
            switch (step) {
                .closed => return error.Closed,
                .discarded => continue,
                .record => |*record| {
                    defer record.deinit();
                    switch (record.kind) {
                        .prompt_rejected => return error.Rejected,
                        .agent_settled => return,
                        else => {},
                    }
                },
            }
        }
    }

    /// Copies the `get_last_assistant_text` reply into `response`. Here an
    /// oversized record can only be the reply itself, so it is invalid
    /// output rather than noise.
    fn readLastText(session: *Session, timeout: Io.Timeout, response: *Response) AskError!void {
        while (true) {
            var step = try session.stream.next(session.gpa, timeout);
            switch (step) {
                .closed => return error.Closed,
                .discarded => return error.InvalidOutput,
                .record => |*record| {
                    defer record.deinit();
                    if (record.kind != .last_text) {
                        continue;
                    }

                    const text = record.text() orelse return error.InvalidOutput;
                    if (text.len == 0 or text.len > types.max_reply_bytes) {
                        return error.InvalidOutput;
                    }

                    @memcpy(response.text[0..text.len], text);
                    response.text_len = @intCast(text.len);
                    return;
                },
            }
        }
    }
};

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toMilliseconds();
}

const fakes = @import("testing.zig");

fn askOnce(io: Io, arguments: []const []const u8, timeout_ms: u32) !Status {
    const session = try Session.open(io, std.testing.allocator, fakes.options(arguments, timeout_ms, 60_000));
    defer session.close(io);

    var response: Response = .{ .purpose = fakes.purpose, .status = .failed };
    return session.ask(io, "Create a title", &response);
}

test "a session answers a prompt with the settled assistant text" {
    const io = std.testing.io;
    const session = try Session.open(io, std.testing.allocator, fakes.options(&.{ "/bin/sh", "-c", fakes.fake_engine }, 5000, 60_000));
    defer session.close(io);

    var response: Response = .{ .purpose = fakes.purpose, .status = .failed };
    try std.testing.expectEqual(Status.success, session.ask(io, "Create a title", &response));
    try std.testing.expectEqualStrings("Improve agent sidebar", response.textSlice());

    // The same child answers again.
    try std.testing.expectEqual(Status.success, session.ask(io, "Create a title", &response));
    try std.testing.expectEqualStrings("Improve agent sidebar", response.textSlice());
}

test "protocol failures map to a status" {
    const io = std.testing.io;
    try std.testing.expectEqual(Status.timeout, try askOnce(io, &.{ "/bin/sh", "-c", fakes.silent_engine }, 100));
    try std.testing.expectEqual(Status.failed, try askOnce(io, &.{ "/bin/sh", "-c", "read -r line; printf '%s\\n' '{\"type\":\"response\",\"command\":\"prompt\",\"success\":false}'; sleep 5" }, 1000));
    try std.testing.expectEqual(Status.failed, try askOnce(io, &.{ "/bin/sh", "-c", "exit 0" }, 1000));
    try std.testing.expectEqual(Status.invalid_output, try askOnce(io, &.{ "/bin/sh", "-c", fakes.empty_reply_engine }, 1000));
}

test "oversized records are dropped and an oversized reply is invalid" {
    const io = std.testing.io;
    const status = try askOnce(io, &.{
        "/bin/sh", "-c",
        \\read -r line
        \\printf '%s\n' '{"type":"response","command":"prompt","success":true}'
        \\head -c 70000 /dev/zero | tr '\0' 'a'; printf '\n'
        \\printf '%s\n' '{"type":"agent_settled"}'
        \\read -r line
        \\printf '{"type":"response","command":"get_last_assistant_text","success":true,"data":{"text":"'
        \\head -c 70000 /dev/zero | tr '\0' 'b'; printf '"}}\n'
        \\sleep 5
    }, 5000);
    try std.testing.expectEqual(Status.invalid_output, status);
}

test "a session without a command cannot open" {
    const io = std.testing.io;
    try std.testing.expectError(error.FileNotFound, Session.open(io, std.testing.allocator, fakes.options(&.{}, 1000, 60_000)));
}
