//! `telar server bridge`: carries one remote client's connection
//! (docs/flows/remote-attach.md). The client's ssh session is this
//! process's standard input and output; the bridge connects to the running
//! runtime and copies bytes both ways unchanged, so the runtime sees an
//! ordinary client of the same user and its framing, bounds and
//! backpressure hold end to end. It never starts a runtime, since discovery
//! just did. When either side ends, the process exits, which ends the other.
const client = @import("telar-client");
const localsocket = @import("localsocket");
const std = @import("std");
const RuntimeConnector = client.RuntimeConnector;

/// Bytes one direction moves per read.
const relay_buffer_bytes = 64 * 1024;

/// Connects to the runtime and relays until either side ends; it does not
/// return then, because the process exits. One thread per direction, so a
/// slow reader on one side never stalls the other.
///
/// ```zig
/// try runtime_bridge.relay(io, &connector);
/// ```
pub fn relay(io: std.Io, connector: *const RuntimeConnector) !void {
    const channel = try localsocket.connect(io, connector.endpointPath());
    const socket = channel.stream.socket.handle;

    const upstream = try std.Thread.spawn(.{}, copyThenExit, .{ io, std.posix.STDIN_FILENO, socket });
    upstream.detach();
    copyThenExit(io, socket, std.posix.STDOUT_FILENO);
}

fn copyThenExit(io: std.Io, from: std.posix.fd_t, to: std.posix.fd_t) void {
    copy(io, from, to);
    std.process.exit(0);
}

// Copies until `from` ends or either side fails.
fn copy(io: std.Io, from: std.posix.fd_t, to: std.posix.fd_t) void {
    var buffer: [relay_buffer_bytes]u8 = undefined;
    const target: std.Io.File = .{ .handle = to, .flags = .{ .nonblocking = false } };
    while (true) {
        const read = std.posix.read(from, &buffer) catch return;
        if (read == 0) {
            return;
        }

        target.writeStreamingAll(io, buffer[0..read]) catch return;
    }
}

test "the bridge copies bytes unchanged until its source ends" {
    const io = std.testing.io;
    var source = try localsocket.pair();
    defer source[1].deinit(io);
    var target = try localsocket.pair();
    defer target[0].deinit(io);
    defer target[1].deinit(io);

    try source[0].send(io, "frame one");
    try source[0].send(io, "frame two");
    source[0].deinit(io);

    copy(io, source[1].stream.socket.handle, target[0].stream.socket.handle);

    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("frame one", try target[1].receive(io, &buffer));
    try std.testing.expectEqualStrings("frame two", try target[1].receive(io, &buffer));
}
