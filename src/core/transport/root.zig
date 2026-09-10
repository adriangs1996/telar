//! Allocation-free framing shared by the backend and frontend.
//!
//! A channel is a reliable byte stream carrying opaque messages. Each message
//! starts with a four-byte little-endian payload length. The schema above this
//! layer decides what those payload bytes mean.

const std = @import("std");
const Io = std.Io;

pub const endpoint = @import("endpoint.zig");

pub const length_prefix_size = @sizeOf(u32);
/// Sized so that a full pane snapshot of a large real screen (for example
/// 480x150) fits one frame even at the worst-case per-cell encoding that
/// `frame.max_cell_size` assumes.
pub const max_frame_size = 4 * 1024 * 1024;

pub const WriteFrameError = Io.Writer.Error || error{ FrameTooLarge, ConnectionClosed };

pub const ReadFrameError = Io.Reader.Error || error{
    ConnectionClosed,
    UnexpectedEndOfStream,
    FrameTooLarge,
    BufferTooSmall,
};

/// Writes one complete frame. No bytes are written when the payload is too
/// large, so callers can recover from that local programming error.
pub fn writeFrame(writer: *Io.Writer, payload: []const u8) WriteFrameError!void {
    if (payload.len > max_frame_size) {
        return error.FrameTooLarge;
    }

    var prefix: [length_prefix_size]u8 = undefined;
    std.mem.writeInt(u32, &prefix, @intCast(payload.len), .little);
    // One vectored write instead of two: this path carries per-keystroke
    // messages, so the prefix must not cost its own syscall.
    var parts = [2][]const u8{ &prefix, payload };
    try writer.writeVecAll(&parts);
    try writer.flush();
}

/// Reads one complete frame into caller-owned memory. Any error after the
/// prefix has been consumed makes the stream unusable; close the channel.
pub fn readFrame(reader: *Io.Reader, buffer: []u8) ReadFrameError![]u8 {
    var prefix: [length_prefix_size]u8 = undefined;
    const prefix_len = try reader.readSliceShort(&prefix);
    if (prefix_len == 0) {
        return error.ConnectionClosed;
    }
    if (prefix_len != prefix.len) {
        return error.UnexpectedEndOfStream;
    }

    const payload_len = std.mem.readInt(u32, &prefix, .little);
    if (payload_len > max_frame_size) {
        return error.FrameTooLarge;
    }
    if (payload_len > buffer.len) {
        return error.BufferTooSmall;
    }

    const payload = buffer[0..payload_len];
    const bytes_read = try reader.readSliceShort(payload);
    if (bytes_read != payload.len) {
        return error.UnexpectedEndOfStream;
    }
    return payload;
}

/// Bytes a channel reads ahead of the frame it was asked for. A burst of small
/// messages then costs one syscall instead of two per message, and the four
/// byte prefix never costs its own `read`.
pub const read_buffer_size = 64 * 1024;

/// Owns a connected raw socket. A channel supports one concurrent reader and
/// one concurrent writer. It must not be copied after ownership is handed to
/// another component.
pub const SocketChannel = struct {
    stream: Io.net.Stream,
    active: std.atomic.Value(bool) = .init(true),
    /// Owner-provided read-ahead storage; empty keeps reads unbuffered, which
    /// is what a handshake on a not-yet-retained channel needs.
    read_buffer: []u8 = &.{},
    /// The persistent reader over `read_buffer`, bound on first buffered read.
    reader: ?Io.net.Stream.Reader = null,

    pub fn init(stream: Io.net.Stream) SocketChannel {
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

    pub fn send(channel: *SocketChannel, io: Io, payload: []const u8) WriteFrameError!void {
        if (!channel.isActive()) {
            return error.ConnectionClosed;
        }
        var stream_writer = channel.stream.writer(io, &.{});
        try writeFrame(&stream_writer.interface, payload);
    }

    pub fn receive(channel: *SocketChannel, io: Io, buffer: []u8) ReadFrameError![]u8 {
        if (!channel.isActive()) {
            return error.ConnectionClosed;
        }
        return readFrame(channel.boundReader(io), buffer);
    }

    /// Returns the reader over `read_buffer`, creating it on first use. An
    /// unbound channel reads exactly one frame per call, so binding later
    /// loses nothing.
    fn boundReader(channel: *SocketChannel, io: Io) *Io.Reader {
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
    pub fn shutdown(channel: *SocketChannel, io: Io) void {
        if (!channel.isActive()) {
            return;
        }
        channel.stream.shutdown(io, .both) catch {};
    }

    pub fn deinit(channel: *SocketChannel, io: Io) void {
        if (!channel.active.swap(false, .acq_rel)) {
            return;
        }
        // Closing a descriptor from another thread does not reliably wake a
        // blocking read on POSIX. Shutdown does, which lets a dead frontend
        // release its runtime connection while the reader actor is pending.
        channel.stream.shutdown(io, .both) catch {};
        channel.stream.close(io);
    }
};

test "frame encoding uses a little-endian length prefix" {
    var bytes: [64]u8 = undefined;
    var writer = Io.Writer.fixed(&bytes);

    try writeFrame(&writer, "telar");

    try std.testing.expectEqualSlices(u8, &.{ 5, 0, 0, 0 }, bytes[0..4]);
    try std.testing.expectEqualStrings("telar", bytes[4..writer.end]);
}

test "frames round trip without allocation" {
    var encoded: [64]u8 = undefined;
    var writer = Io.Writer.fixed(&encoded);
    try writeFrame(&writer, "one pane");

    var reader = Io.Reader.fixed(encoded[0..writer.end]);
    var payload: [32]u8 = undefined;
    const decoded = try readFrame(&reader, &payload);

    try std.testing.expectEqualStrings("one pane", decoded);
}

test "empty frames are valid" {
    var encoded: [length_prefix_size]u8 = undefined;
    var writer = Io.Writer.fixed(&encoded);
    try writeFrame(&writer, "");

    var reader = Io.Reader.fixed(&encoded);
    const decoded = try readFrame(&reader, &.{});
    try std.testing.expectEqual(@as(usize, 0), decoded.len);
}

test "oversized writes fail before writing a prefix" {
    var sink: [length_prefix_size]u8 = undefined;
    var writer = Io.Writer.fixed(&sink);
    const oversized: []const u8 = @as([*]const u8, @ptrFromInt(1))[0 .. max_frame_size + 1];

    try std.testing.expectError(error.FrameTooLarge, writeFrame(&writer, oversized));
    try std.testing.expectEqual(@as(usize, 0), writer.end);
}

test "declared oversized frames are rejected before reading a body" {
    var prefix: [length_prefix_size]u8 = undefined;
    std.mem.writeInt(u32, &prefix, max_frame_size + 1, .little);
    var reader = Io.Reader.fixed(&prefix);
    var payload: [8]u8 = undefined;

    try std.testing.expectError(error.FrameTooLarge, readFrame(&reader, &payload));
}

test "a frame must fit in caller-owned memory" {
    const encoded = [_]u8{ 5, 0, 0, 0 } ++ "telar".*;
    var reader = Io.Reader.fixed(&encoded);
    var payload: [4]u8 = undefined;

    try std.testing.expectError(error.BufferTooSmall, readFrame(&reader, &payload));
}

test "frames survive a reader that returns one byte at a time" {
    // Socket reads split anywhere, including inside the length prefix. The
    // framing must reassemble a frame from arbitrarily small reads.
    const Dribble = struct {
        bytes: []const u8,
        index: usize = 0,
        interface: Io.Reader = .{
            .vtable = &.{ .stream = stream },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        },

        fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
            const d: *@This() = @alignCast(@fieldParentPtr("interface", r));
            if (d.index == d.bytes.len) {
                return error.EndOfStream;
            }
            if (limit.minInt(1) == 0) {
                return 0;
            }
            const n = try w.write(d.bytes[d.index..][0..1]);
            d.index += n;
            return n;
        }
    };

    var encoded: [64]u8 = undefined;
    var writer = Io.Writer.fixed(&encoded);
    try writeFrame(&writer, "split me anywhere");
    try writeFrame(&writer, "second frame");

    var dribble: Dribble = .{ .bytes = encoded[0..writer.end] };
    var payload: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "split me anywhere",
        try readFrame(&dribble.interface, &payload),
    );
    try std.testing.expectEqualStrings(
        "second frame",
        try readFrame(&dribble.interface, &payload),
    );
    try std.testing.expectError(
        error.ConnectionClosed,
        readFrame(&dribble.interface, &payload),
    );
}

test "clean close and truncated frames are distinct" {
    var empty_reader = Io.Reader.fixed(&.{});
    var payload: [8]u8 = undefined;
    try std.testing.expectError(error.ConnectionClosed, readFrame(&empty_reader, &payload));

    var short_prefix_reader = Io.Reader.fixed(&.{ 1, 0 });
    try std.testing.expectError(
        error.UnexpectedEndOfStream,
        readFrame(&short_prefix_reader, &payload),
    );

    var short_payload_reader = Io.Reader.fixed(&.{ 3, 0, 0, 0, 'a', 'b' });
    try std.testing.expectError(
        error.UnexpectedEndOfStream,
        readFrame(&short_payload_reader, &payload),
    );
}
