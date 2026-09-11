const std = @import("std");
const transport = @import("transport.zig");
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
pub fn bindReadBuffer(channel: *SocketChannel, buffer: []u8) void {
    channel.read_buffer = buffer;
    channel.reader = null;
}

pub fn send(channel: *SocketChannel, io: std.Io, payload: []const u8) transport.WriteFrameError!void {
    if (!channel.isActive()) {
        return error.ConnectionClosed;
    }
    var stream_writer = channel.stream.writer(io, &.{});
    try transport.writeFrame(&stream_writer.interface, payload);
}

pub fn receive(channel: *SocketChannel, io: std.Io, buffer: []u8) transport.ReadFrameError![]u8 {
    if (!channel.isActive()) {
        return error.ConnectionClosed;
    }
    return transport.readFrame(channel.boundReader(io), buffer);
}

/// Returns the reader over `read_buffer`, creating it on first use. An
/// unbound channel reads exactly one frame per call, so binding later
/// loses nothing.
fn boundReader(channel: *SocketChannel, io: std.Io) *std.Io.Reader {
    if (channel.reader) |*reader| {
        return &reader.interface;
    }

    channel.reader = channel.stream.reader(io, channel.read_buffer);
    return &channel.reader.?.interface;
}

pub fn isActive(channel: *const SocketChannel) bool {
    return channel.active.load(.acquire);
}

/// Interrupts pending reads and writes without releasing the descriptor.
/// The owner can wait for its I/O actors before calling `deinit`.
pub fn shutdown(channel: *SocketChannel, io: std.Io) void {
    if (!channel.isActive()) {
        return;
    }
    channel.stream.shutdown(io, .both) catch {};
}

pub fn deinit(channel: *SocketChannel, io: std.Io) void {
    if (!channel.active.swap(false, .acq_rel)) {
        return;
    }
    // Closing a descriptor from another thread does not reliably wake a
    // blocking read on POSIX. Shutdown does, which lets a dead frontend
    // release its runtime connection while the reader actor is pending.
    channel.stream.shutdown(io, .both) catch {};
    channel.stream.close(io);
}
