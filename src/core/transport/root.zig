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

/// Encodes the length prefix that precedes every frame on the wire.
///
/// ```zig
/// writePrefix(buffer[0..length_prefix_size], payload.len);
/// ```
pub fn writePrefix(prefix: *[length_prefix_size]u8, payload_len: usize) void {
    std.mem.writeInt(u32, prefix, @intCast(payload_len), .little);
}

/// Walks the frames of a batch produced by prefixing each payload, as one
/// `sendFramed` carries them. A truncated tail ends the walk.
///
/// ```zig
/// var frames = FrameIterator{ .batch = batch };
/// while (frames.next()) |payload| handle(payload);
/// ```
pub const FrameIterator = struct {
    batch: []const u8,
    offset: usize = 0,

    pub fn next(frames: *FrameIterator) ?[]const u8 {
        if (frames.offset + length_prefix_size > frames.batch.len) {
            return null;
        }
        const len = std.mem.readInt(u32, frames.batch[frames.offset..][0..length_prefix_size], .little);
        if (frames.offset + length_prefix_size + len > frames.batch.len) {
            return null;
        }
        const payload = frames.batch[frames.offset + length_prefix_size ..][0..len];
        frames.offset += length_prefix_size + len;
        return payload;
    }
};

/// Writes one complete frame. No bytes are written when the payload is too
/// large, so callers can recover from that local programming error.
pub fn writeFrame(writer: *Io.Writer, payload: []const u8) WriteFrameError!void {
    if (payload.len > max_frame_size) {
        return error.FrameTooLarge;
    }

    var prefix: [length_prefix_size]u8 = undefined;
    writePrefix(&prefix, payload.len);
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

/// Kernel buffer requested on each end of a connection. A stream socket
/// reports the peer's receive space as its send space, so both ends ask for
/// the same size.
pub const socket_buffer_size = 256 * 1024;

/// Send low-water mark. A positive writable poll then means at least this
/// much room, and a blocking send of at most this many bytes returns without
/// sleeping. It never exceeds the platform's default stream buffer, so a peer
/// that kept the default cannot leave a larger blocked send waiting for room
/// that can never exist.
pub const inline_send_low_water = 8 * 1024;

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
    /// Bytes a positive writable poll lets a blocking send take without
    /// sleeping. Zero until `configure` established the low-water mark.
    inline_send_limit: usize = 0,

    pub fn init(stream: Io.net.Stream) SocketChannel {
        return .{ .stream = stream };
    }

    /// Sizes the kernel buffers and sets the send low-water mark behind
    /// `canSendInline`. Best effort: a kernel that refuses the mark keeps
    /// the channel on actor sends only.
    ///
    /// ```zig
    /// channel.configure();
    /// ```
    pub fn configure(channel: *SocketChannel) void {
        const fd = channel.stream.socket.handle;
        _ = setOption(fd, std.c.SO.SNDBUF, socket_buffer_size);
        _ = setOption(fd, std.c.SO.RCVBUF, socket_buffer_size);
        if (!setOption(fd, std.c.SO.SNDLOWAT, inline_send_low_water)) {
            return;
        }

        const low_water = getOption(fd, std.c.SO.SNDLOWAT) orelse return;
        channel.inline_send_limit = @min(low_water, inline_send_low_water);
    }

    /// Whether a blocking send of `payload` completes right now without
    /// sleeping: the payload fits under the low-water mark and the kernel
    /// reports that much room. The answer is only valid while no other
    /// writer touches the socket.
    ///
    /// ```zig
    /// if (channel.canSendInline(batch)) { try channel.sendFramed(io, batch); }
    /// ```
    pub fn canSendInline(channel: *const SocketChannel, payload: []const u8) bool {
        if (payload.len == 0 or payload.len > channel.inline_send_limit or !channel.isActive()) {
            return false;
        }

        var polling = [1]std.c.pollfd{.{ .fd = channel.stream.socket.handle, .events = std.posix.POLL.OUT, .revents = 0 }};
        const ready = std.c.poll(&polling, polling.len, 0);
        return ready > 0 and polling[0].revents & std.posix.POLL.OUT != 0;
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

    /// Writes bytes that already carry their frame prefixes, so a batch of
    /// messages leaves in one syscall. The receiver reads them one frame at
    /// a time as usual.
    ///
    /// ```zig
    /// try channel.sendFramed(io, batch);
    /// ```
    pub fn sendFramed(channel: *SocketChannel, io: Io, framed: []const u8) WriteFrameError!void {
        if (!channel.isActive()) {
            return error.ConnectionClosed;
        }
        var stream_writer = channel.stream.writer(io, &.{});
        try stream_writer.interface.writeAll(framed);
        try stream_writer.interface.flush();
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

fn setOption(fd: std.c.fd_t, option: u32, value: c_int) bool {
    return std.c.setsockopt(fd, std.c.SOL.SOCKET, option, &value, @sizeOf(c_int)) == 0;
}

fn getOption(fd: std.c.fd_t, option: u32) ?usize {
    var value: c_int = 0;
    var len: std.c.socklen_t = @sizeOf(c_int);
    if (std.c.getsockopt(fd, std.c.SOL.SOCKET, option, &value, &len) != 0 or value <= 0) {
        return null;
    }

    return @intCast(value);
}

fn testSocketPair() ![2]SocketChannel {
    var sockets: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets) != 0) {
        return error.SocketPairFailed;
    }

    return .{
        .init(.{ .socket = .{ .handle = sockets[0], .address = .{ .ip4 = .loopback(0) } } }),
        .init(.{ .socket = .{ .handle = sockets[1], .address = .{ .ip4 = .loopback(0) } } }),
    };
}

test "an unconfigured channel never offers an inline send" {
    var pair = try testSocketPair();
    defer for (&pair) |*channel| channel.deinit(std.testing.io);

    try std.testing.expect(!pair[0].canSendInline("x"));
}

test "a configured channel offers inline sends only under the low-water mark and while room exists" {
    const io = std.testing.io;
    var pair = try testSocketPair();
    defer for (&pair) |*channel| channel.deinit(io);
    pair[0].configure();
    pair[1].configure();
    try std.testing.expect(pair[0].inline_send_limit > 0);
    try std.testing.expect(pair[0].inline_send_limit <= inline_send_low_water);

    const small = [_]u8{'x'} ** 64;
    const oversized = [_]u8{'x'} ** (inline_send_low_water + 1);
    try std.testing.expect(pair[0].canSendInline(&small));
    try std.testing.expect(!pair[0].canSendInline(&oversized));
    try std.testing.expect(!pair[0].canSendInline(""));

    // Fill the peer's receive space without reading; every guarded send
    // must return, and the offer must stop before a send could sleep.
    var filled: usize = 0;
    while (pair[0].canSendInline(&small)) {
        var stream_writer = pair[0].stream.writer(io, &.{});
        try stream_writer.interface.writeAll(&small);
        try stream_writer.interface.flush();
        filled += small.len;
        try std.testing.expect(filled <= 2 * socket_buffer_size);
    }

    try std.testing.expect(filled >= pair[0].inline_send_limit);
    var drain: [4096]u8 = undefined;
    var stream_reader = pair[1].stream.reader(io, &drain);
    _ = try stream_reader.interface.readSliceShort(&drain);
}

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
