//! A validated IPC message borrowing the transport's reserved receive buffer.
//! The consumer finishes application before rearming that buffer's producer.
const std = @import("std");
const core = @import("telar-core");

message: core.ServerMessage,
payload_len: usize,
decode_ns: u64,

/// Decode on the receiving producer. Example: `return RuntimeMessage.decode(io, bytes);`
pub fn decode(io: std.Io, payload: []const u8) !@This() {
    const start = core.now(io);
    const message = try core.decodeServer(payload);
    return .{ .message = message, .payload_len = payload.len, .decode_ns = core.elapsed(start, core.now(io)) };
}
