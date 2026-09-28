//! A validated IPC message borrowing the transport's reserved receive buffer.
//! The consumer finishes application before rearming that buffer's producer.
const std = @import("std");
const core = @import("telar-core");
const RuntimeMessage = @This();

message: core.ServerMessage,
payload_len: usize,
decode_ns: u64,

/// Decode on the receiving producer. Example: `return RuntimeMessage.decode(io, bytes);`
pub fn decode(io: std.Io, payload: []const u8) !RuntimeMessage {
    var received: RuntimeMessage = undefined;
    try received.decodeInto(io, payload);
    return received;
}

/// Decodes in place, writing only the variant the payload carries.
/// Example: `try self.received.decodeInto(io, bytes);`
pub fn decodeInto(self: *RuntimeMessage, io: std.Io, payload: []const u8) !void {
    const start = core.now(io);
    try core.decodeServerInto(&self.message, payload);
    self.payload_len = payload.len;
    self.decode_ns = core.elapsed(start, core.now(io));
}
