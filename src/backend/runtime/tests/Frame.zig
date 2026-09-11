const Frame = @This();
const std = @import("std");
const source_namespace = @import("shared_frame_test.zig");
name_buffer: [std.fs.max_path_bytes]u8 = undefined,
name_len: usize = 0,
envelope: [512]u8 = undefined,
envelope_len: usize = 0,

pub fn name(frame: *const Frame) [:0]const u8 {
    return frame.name_buffer[0..frame.name_len :0];
}

pub fn bytes(frame: *const Frame) []const u8 {
    return frame.envelope[0..frame.envelope_len];
}

/// Publishes `pixels` the way terminal-browser does: a fresh object and
/// one synchronized envelope naming it.
pub fn publish(frame: *Frame, sequence: u32, pixels: []const u8) !void {
    const name_z = try std.fmt.bufPrintZ(&frame.name_buffer, "/tlrtest-frame-{d}-{d}", .{ std.c.getpid(), sequence });
    frame.name_len = name_z.len;
    _ = std.c.shm_unlink(name_z);
    try source_namespace.createChildObject(name_z, pixels);
    const Encoder = std.base64.standard.Encoder;
    var encoded: [128]u8 = undefined;
    const payload = Encoder.encode(encoded[0..Encoder.calcSize(name_z.len)], name_z);
    const envelope = try std.fmt.bufPrint(
        &frame.envelope,
        "\x1b[?2026h\x1b[H\x1b_Ga=T,f=32,s=2,v=1,t=s,i=7,p=1,C=1,q=2;{s}\x1b\\\x1b[?2026l",
        .{payload},
    );
    frame.envelope_len = envelope.len;
}

/// Publishes `pixels` through a regular file, terminal-browser's
/// preferred transport, and builds the matching `t=f` envelope.
pub fn publishFile(frame: *Frame, directory: []const u8, pixels: []const u8) !void {
    const file_path = try std.fmt.bufPrint(&frame.name_buffer, "{s}/frame.rgba", .{directory});
    frame.name_len = file_path.len;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = pixels });
    const Encoder = std.base64.standard.Encoder;
    var encoded: [512]u8 = undefined;
    const payload = Encoder.encode(encoded[0..Encoder.calcSize(file_path.len)], file_path);
    const envelope = try std.fmt.bufPrint(
        &frame.envelope,
        "\x1b[?2026h\x1b[H\x1b_Ga=T,f=32,s=2,v=1,t=f,i=7,p=1,C=1,q=2;{s}\x1b\\\x1b[?2026l",
        .{payload},
    );
    frame.envelope_len = envelope.len;
}

pub fn path(frame: *const Frame) []const u8 {
    return frame.name_buffer[0..frame.name_len];
}
