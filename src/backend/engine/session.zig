const Session = @This();
const std = @import("std");
const rpc = @import("rpc.zig");
const source_namespace = @import("session_support.zig");
const Request = @import("Request.zig");
const types = @import("types.zig");
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
pub fn open(io: source_namespace.Io, gpa: std.mem.Allocator, options: source_namespace.Options) !*Session {
    if (options.arguments.len == 0) {
        return error.FileNotFound;
    }

    const session = try gpa.create(Session);
    errdefer gpa.destroy(session);
    session.* = .{
        .gpa = gpa,
        .timeout_ms = options.timeout_ms,
        .child = undefined,
        .last_used_ms = source_namespace.nowMs(io),
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
pub fn close(session: *Session, io: source_namespace.Io) void {
    session.stream.deinit();
    session.child.kill(io);
    session.gpa.destroy(session);
}

/// Sends one prompt and waits for the settled assistant text within the
/// session deadline. The text is copied into `response` on success.
///
/// ```zig
/// response.status = session.ask(io, .{ .prompt = prompt.slice(), .response = &response });
/// ```
pub fn ask(session: *Session, io: source_namespace.Io, request: Request) source_namespace.Status {
    session.exchange(io, request) catch |err| return switch (err) {
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
pub fn touch(session: *Session, io: source_namespace.Io) void {
    session.last_used_ms = source_namespace.nowMs(io);
}

/// Milliseconds since the session was opened or last touched.
///
/// ```zig
/// if (session.idleMs(io) >= idle_timeout_ms) session.close(io);
/// ```
pub fn idleMs(session: *const Session, io: source_namespace.Io) i64 {
    return source_namespace.nowMs(io) - session.last_used_ms;
}

fn exchange(session: *Session, io: source_namespace.Io, request: Request) source_namespace.AskError!void {
    const timeout: source_namespace.Io.Timeout = .{ .deadline = .fromNow(io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(session.timeout_ms),
    }) };

    const prompt_line = try rpc.encodePrompt(&session.line_buffer, request.prompt);
    try session.writeLine(io, prompt_line);
    try session.awaitSettled(timeout);

    const query_line = try rpc.encodeCommand(&session.line_buffer, "get_last_assistant_text");
    try session.writeLine(io, query_line);
    try session.readLastText(timeout, request.response);
}

fn writeLine(session: *Session, io: source_namespace.Io, line: []const u8) source_namespace.AskError!void {
    const stdin = session.child.stdin orelse return error.WriteFailed;
    stdin.writeStreamingAll(io, line) catch return error.WriteFailed;
}

/// Consumes records until the agent settles. A rejected prompt ends the
/// dialogue; oversized records are ignored.
fn awaitSettled(session: *Session, timeout: source_namespace.Io.Timeout) source_namespace.AskError!void {
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
fn readLastText(session: *Session, timeout: source_namespace.Io.Timeout, response: *source_namespace.Response) source_namespace.AskError!void {
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
