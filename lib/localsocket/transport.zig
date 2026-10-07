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
