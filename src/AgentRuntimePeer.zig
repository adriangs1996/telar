const std = @import("std");
const core = @import("telar-core");
const Channel = @import("RuntimeTestChannel.zig");

io: std.Io,
channel: Channel,
open: bool = true,
send_buffer: [16 * 1024]u8 = undefined,
receive_buffer: [128 * 1024]u8 = undefined,

/// Example: `var peer = try AgentRuntimePeer.init(io, path);`
pub fn init(io: std.Io, path: []const u8) !@This() {
    return .{ .io = io, .channel = try @import("transport_integration_test.zig").connectRuntimeForTest(io, path) };
}

/// Example: `peer.deinit();`
pub fn deinit(peer: *@This()) void {
    if (peer.open) {
        peer.channel.deinit(peer.io);
        peer.open = false;
    }
}

/// Example: `try peer.send(encoded);`
pub fn send(peer: *@This(), bytes: []const u8) !void {
    try peer.channel.send(peer.io, bytes);
}

/// Consumes terminal frame acknowledgements while exercising typed agent IPC.
/// Example: `const message = try peer.receive();`.
pub fn receive(peer: *@This()) !core.ServerMessage {
    while (true) {
        const message = try core.decodeServer(try peer.channel.receive(peer.io, &peer.receive_buffer));
        switch (message) {
            .pane_frame => |frame| try peer.send(try core.encodeFrameAck(&peer.send_buffer, .{ .pane_id = frame.pane_id, .frame_id = frame.frame_id })),
            .request_failed => |failure| {
                std.debug.print("agent runtime request failed: {s}\n", .{failure.message});
                return error.AgentRuntimeRequestFailed;
            },
            else => return message,
        }
    }
}
