const std = @import("std");
const transport = @import("transport.zig");
const listen = @import("listen.zig");
/// Owns a connected raw socket. A channel supports one concurrent reader and
/// one concurrent writer. It must not be copied after ownership is handed to
/// another component.
const SocketChannel = @This();

stream: std.Io.net.Stream,
active: std.atomic.Value(bool) = .init(true),
/// Owner-provided read-ahead storage; empty keeps reads unbuffered, which
/// is what a handshake on a not-yet-retained channel needs.
read_buffer: []u8 = &.{},
/// The persistent reader over `read_buffer`, bound on first buffered read.
reader: ?std.Io.net.Stream.Reader = null,

pub fn init(stream: std.Io.net.Stream) SocketChannel {
    return .{ .stream = stream };
}

/// Gives the channel read-ahead storage it does not own. Bind after the
/// channel reached its final address; the owner frees the buffer after
/// the channel's last read completed.
///
/// ```zig
/// session.connection.bindReadBuffer(read_buffer);
/// ```
pub fn bindReadBuffer(self: *SocketChannel, buffer: []u8) void {
    self.read_buffer = buffer;
    self.reader = null;
}

pub fn send(self: *SocketChannel, io: std.Io, payload: []const u8) transport.WriteFrameError!void {
    if (!self.isActive()) {
        return error.ConnectionClosed;
    }
    var stream_writer = self.stream.writer(io, &.{});
    try transport.writeFrame(&stream_writer.interface, payload);
}

pub fn receive(self: *SocketChannel, io: std.Io, buffer: []u8) transport.ReadFrameError![]u8 {
    if (!self.isActive()) {
        return error.ConnectionClosed;
    }
    return transport.readFrame(self.boundReader(io), buffer);
}

/// Returns the reader over `read_buffer`, creating it on first use. An
/// unbound channel reads exactly one frame per call, so binding later
/// loses nothing.
fn boundReader(self: *SocketChannel, io: std.Io) *std.Io.Reader {
    if (self.reader) |*reader| {
        return &reader.interface;
    }

    self.reader = self.stream.reader(io, self.read_buffer);
    return &self.reader.?.interface;
}

/// The process that opened the other end of the connection.
///
/// ```zig
/// const pid = try session.connection.peerProcess();
/// ```
pub fn peerProcess(self: *const SocketChannel) !u32 {
    return listen.peerProcess(self.stream.socket.handle);
}

pub fn isActive(self: *const SocketChannel) bool {
    return self.active.load(.acquire);
}

/// Interrupts pending reads and writes without releasing the descriptor.
/// The owner can wait for its I/O actors before calling `deinit`.
pub fn shutdown(self: *SocketChannel, io: std.Io) void {
    if (!self.isActive()) {
        return;
    }
    self.stream.shutdown(io, .both) catch {};
}

pub fn deinit(self: *SocketChannel, io: std.Io) void {
    if (!self.active.swap(false, .acq_rel)) {
        return;
    }
    // Closing a descriptor from another thread does not reliably wake a
    // blocking read on POSIX. Shutdown does, which lets a dead frontend
    // release its runtime connection while the reader actor is pending.
    self.stream.shutdown(io, .both) catch {};
    self.stream.close(io);
}
