const std = @import("std");
const Stream = @import("Stream.zig");
const rpc = @import("rpc.zig");
const Options = @import("Options.zig");
const session_support = @import("session_support.zig");
const types = @import("types.zig");
const Reply = @import("Reply.zig");
const Session = @This();

gpa: std.mem.Allocator,
timeout_ms: u32,
child: std.process.Child,
stream: Stream = .{},
line_buffer: [rpc.max_line_bytes]u8 = undefined,
last_used_ms: i64,

/// Spawns the engine command. Fails with `error.FileNotFound` when there
/// is no command to run, so callers can report `unavailable`.
///
/// ```zig
/// const session = try Session.open(io, gpa, options);
/// defer session.close(io);
/// ```
pub fn open(io: std.Io, gpa: std.mem.Allocator, options: Options) !*Session {
    if (options.arguments.len == 0) {
        return error.FileNotFound;
    }

    const session = try gpa.create(Session);
    errdefer gpa.destroy(session);
    session.* = .{
        .gpa = gpa,
        .timeout_ms = options.timeout_ms,
        .child = undefined,
        .last_used_ms = session_support.nowMs(io),
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
pub fn close(self: *Session, io: std.Io) void {
    self.stream.deinit();
    self.child.kill(io);
    self.gpa.destroy(self);
}

/// Sends one prompt and waits for the settled assistant text within the
/// session deadline. The text is copied into `reply` on success.
///
/// ```zig
/// const status = session.ask(io, prompt.slice(), &reply);
/// ```
pub fn ask(self: *Session, io: std.Io, prompt: []const u8, reply: *Reply) types.Status {
    self.exchange(io, prompt, reply) catch |err| return switch (err) {
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
pub fn touch(self: *Session, io: std.Io) void {
    self.last_used_ms = session_support.nowMs(io);
}

/// Milliseconds since the session was opened or last touched.
///
/// ```zig
/// if (session.idleMs(io) >= idle_timeout_ms) session.close(io);
/// ```
pub fn idleMs(self: *const Session, io: std.Io) i64 {
    return session_support.nowMs(io) - self.last_used_ms;
}

fn exchange(self: *Session, io: std.Io, prompt: []const u8, reply: *Reply) session_support.AskError!void {
    const timeout: std.Io.Timeout = .{ .deadline = .fromNow(io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(self.timeout_ms),
    }) };

    const prompt_line = try rpc.encodePrompt(&self.line_buffer, prompt);
    try self.writeLine(io, prompt_line);
    try self.awaitSettled(timeout);

    const query_line = try rpc.encodeCommand(&self.line_buffer, "get_last_assistant_text");
    try self.writeLine(io, query_line);
    try self.readLastText(timeout, reply);
}

fn writeLine(self: *Session, io: std.Io, line: []const u8) session_support.AskError!void {
    const stdin = self.child.stdin orelse return error.WriteFailed;
    stdin.writeStreamingAll(io, line) catch return error.WriteFailed;
}

/// Consumes records until the agent settles. A rejected prompt ends the
/// dialogue; oversized records are ignored.
fn awaitSettled(self: *Session, timeout: std.Io.Timeout) session_support.AskError!void {
    while (true) {
        var step = try self.stream.next(self.gpa, timeout);
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

/// Copies the `get_last_assistant_text` reply into `reply`. Here an
/// oversized record can only be the reply itself, so it is invalid
/// output rather than noise.
fn readLastText(self: *Session, timeout: std.Io.Timeout, reply: *Reply) session_support.AskError!void {
    while (true) {
        var step = try self.stream.next(self.gpa, timeout);
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

                @memcpy(reply.bytes[0..text.len], text);
                reply.len = @intCast(text.len);
                return;
            },
        }
    }
}
