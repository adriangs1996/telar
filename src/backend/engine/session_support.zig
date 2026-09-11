//! One engine child and the dialogue that turns a prompt into its reply.
//!
//! A session spawns the command on `open`, keeps its pipes for as long as
//! the actor reuses it, and is killed on `close`. `ask` speaks the Pi RPC
//! dialogue: send the prompt, wait for the agent to settle, then query the
//! last assistant text. Every failure surfaces as a `Status`; what happens
//! to the child afterwards is the actor's decision, never the session's.

const SessionType = @import("Session.zig");
const std = @import("std");
const types = @import("types.zig");
const fakes = @import("testing.zig");
const Response = @import("Response.zig");

pub const AskError = error{ Timeout, ReadFailed, Closed, Rejected, InvalidOutput, WriteFailed };

pub const Request = @import("Request.zig");

pub const Session = @import("Session.zig");

pub fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn askOnce(io: std.Io, arguments: []const []const u8, timeout_ms: u32) !types.Status {
    const session = try SessionType.open(io, std.testing.allocator, fakes.options(arguments, timeout_ms, 60_000));
    defer session.close(io);

    var response: Response = .{ .purpose = fakes.purpose, .status = .failed };
    return session.ask(io, .{ .prompt = "Create a title", .response = &response });
}

test "a session answers a prompt with the settled assistant text" {
    const io = std.testing.io;
    const session = try SessionType.open(io, std.testing.allocator, fakes.options(&.{ "/bin/sh", "-c", fakes.fake_engine }, 5000, 60_000));
    defer session.close(io);

    var response: Response = .{ .purpose = fakes.purpose, .status = .failed };
    try std.testing.expectEqual(types.Status.success, session.ask(io, .{ .prompt = "Create a title", .response = &response }));
    try std.testing.expectEqualStrings("Improve agent sidebar", response.textSlice());

    // The same child answers again.
    try std.testing.expectEqual(types.Status.success, session.ask(io, .{ .prompt = "Create a title", .response = &response }));
    try std.testing.expectEqualStrings("Improve agent sidebar", response.textSlice());
}

test "protocol failures map to a status" {
    const io = std.testing.io;
    try std.testing.expectEqual(types.Status.timeout, try askOnce(io, &.{ "/bin/sh", "-c", fakes.silent_engine }, 100));
    try std.testing.expectEqual(types.Status.failed, try askOnce(io, &.{ "/bin/sh", "-c", "read -r line; printf '%s\\n' '{\"type\":\"response\",\"command\":\"prompt\",\"success\":false}'; sleep 5" }, 1000));
    try std.testing.expectEqual(types.Status.failed, try askOnce(io, &.{ "/bin/sh", "-c", "exit 0" }, 1000));
    try std.testing.expectEqual(types.Status.invalid_output, try askOnce(io, &.{ "/bin/sh", "-c", fakes.empty_reply_engine }, 1000));
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
    try std.testing.expectEqual(types.Status.invalid_output, status);
}

test "a session without a command cannot open" {
    const io = std.testing.io;
    try std.testing.expectError(error.FileNotFound, SessionType.open(io, std.testing.allocator, fakes.options(&.{}, 1000, 60_000)));
}
