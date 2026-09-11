//! Allocation-free framing shared by the backend and frontend.
//!
//! A channel is a reliable byte stream carrying opaque messages. Each message
//! starts with a four-byte little-endian payload length. The schema above this
//! layer decides what those payload bytes mean.

const std = @import("std");

pub const length_prefix_size = @sizeOf(u32);
/// Sized so that a full pane snapshot of a large real screen (for example
/// 480x150) fits one frame even at the worst-case per-cell encoding that
/// `frame.max_cell_size` assumes.
pub const max_frame_size = 4 * 1024 * 1024;

pub const WriteFrameError = std.Io.Writer.Error || error{ FrameTooLarge, ConnectionClosed };

pub const ReadFrameError = std.Io.Reader.Error || error{
    ConnectionClosed,
    UnexpectedEndOfStream,
    FrameTooLarge,
    BufferTooSmall,
};

/// Writes one complete frame. No bytes are written when the payload is too
/// large, so callers can recover from that local programming error.
pub fn writeFrame(writer: *std.Io.Writer, payload: []const u8) WriteFrameError!void {
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
pub fn readFrame(reader: *std.Io.Reader, buffer: []u8) ReadFrameError![]u8 {
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

test "frame encoding uses a little-endian length prefix" {
    var bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);

    try writeFrame(&writer, "telar");

    try std.testing.expectEqualSlices(u8, &.{ 5, 0, 0, 0 }, bytes[0..4]);
    try std.testing.expectEqualStrings("telar", bytes[4..writer.end]);
}

test "frames round trip without allocation" {
    var encoded: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&encoded);
    try writeFrame(&writer, "one pane");

    var reader = std.Io.Reader.fixed(encoded[0..writer.end]);
    var payload: [32]u8 = undefined;
    const decoded = try readFrame(&reader, &payload);

    try std.testing.expectEqualStrings("one pane", decoded);
}

test "empty frames are valid" {
    var encoded: [length_prefix_size]u8 = undefined;
    var writer = std.Io.Writer.fixed(&encoded);
    try writeFrame(&writer, "");

    var reader = std.Io.Reader.fixed(&encoded);
    const decoded = try readFrame(&reader, &.{});
    try std.testing.expectEqual(@as(usize, 0), decoded.len);
}

test "oversized writes fail before writing a prefix" {
    var sink: [length_prefix_size]u8 = undefined;
    var writer = std.Io.Writer.fixed(&sink);
    const oversized: []const u8 = @as([*]const u8, @ptrFromInt(1))[0 .. max_frame_size + 1];

    try std.testing.expectError(error.FrameTooLarge, writeFrame(&writer, oversized));
    try std.testing.expectEqual(@as(usize, 0), writer.end);
}

test "declared oversized frames are rejected before reading a body" {
    var prefix: [length_prefix_size]u8 = undefined;
    std.mem.writeInt(u32, &prefix, max_frame_size + 1, .little);
    var reader = std.Io.Reader.fixed(&prefix);
    var payload: [8]u8 = undefined;

    try std.testing.expectError(error.FrameTooLarge, readFrame(&reader, &payload));
}

test "a frame must fit in caller-owned memory" {
    const encoded = [_]u8{ 5, 0, 0, 0 } ++ "telar".*;
    var reader = std.Io.Reader.fixed(&encoded);
    var payload: [4]u8 = undefined;

    try std.testing.expectError(error.BufferTooSmall, readFrame(&reader, &payload));
}

test "frames survive a reader that returns one byte at a time" {
    // Socket reads split anywhere, including inside the length prefix. The
    // framing must reassemble a frame from arbitrarily small reads.
    const Dribble = struct {
        bytes: []const u8,
        index: usize = 0,
        interface: std.Io.Reader = .{
            .vtable = &.{ .stream = stream },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        },

        fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
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
    var writer = std.Io.Writer.fixed(&encoded);
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
    var empty_reader = std.Io.Reader.fixed(&.{});
    var payload: [8]u8 = undefined;
    try std.testing.expectError(error.ConnectionClosed, readFrame(&empty_reader, &payload));

    var short_prefix_reader = std.Io.Reader.fixed(&.{ 1, 0 });
    try std.testing.expectError(
        error.UnexpectedEndOfStream,
        readFrame(&short_prefix_reader, &payload),
    );

    var short_payload_reader = std.Io.Reader.fixed(&.{ 3, 0, 0, 0, 'a', 'b' });
    try std.testing.expectError(
        error.UnexpectedEndOfStream,
        readFrame(&short_payload_reader, &payload),
    );
}
