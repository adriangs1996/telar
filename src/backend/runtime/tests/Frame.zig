const std = @import("std");
const shared_frame_test = @import("shared_frame_test.zig");
const Frame = @This();

name_buffer: [std.fs.max_path_bytes]u8 = undefined,
name_len: usize = 0,
envelope: [512]u8 = undefined,
envelope_len: usize = 0,

pub fn name(self: *const Frame) [:0]const u8 {
    return self.name_buffer[0..self.name_len :0];
}

pub fn bytes(self: *const Frame) []const u8 {
    return self.envelope[0..self.envelope_len];
}

/// Publishes `pixels` the way terminal-browser does: a fresh object and
/// one synchronized envelope naming it.
pub fn publish(self: *Frame, sequence: u32, pixels: []const u8) !void {
    const name_z = try std.fmt.bufPrintZ(&self.name_buffer, "/tlrtest-frame-{d}-{d}", .{ std.c.getpid(), sequence });
    self.name_len = name_z.len;
    _ = std.c.shm_unlink(name_z);
    try shared_frame_test.createChildObject(name_z, pixels);
    const Encoder = std.base64.standard.Encoder;
    var encoded: [128]u8 = undefined;
    const payload = Encoder.encode(encoded[0..Encoder.calcSize(name_z.len)], name_z);
    const envelope = try std.fmt.bufPrint(
        &self.envelope,
        "\x1b[?2026h\x1b[H\x1b_Ga=T,f=32,s=2,v=1,t=s,i=7,p=1,C=1,q=2;{s}\x1b\\\x1b[?2026l",
        .{payload},
    );
    self.envelope_len = envelope.len;
}

/// Publishes `pixels` through a regular file, terminal-browser's
/// preferred transport, and builds the matching `t=f` envelope.
pub fn publishFile(self: *Frame, directory: []const u8, pixels: []const u8) !void {
    const file_path = try std.fmt.bufPrint(&self.name_buffer, "{s}/frame.rgba", .{directory});
    self.name_len = file_path.len;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = pixels });
    const Encoder = std.base64.standard.Encoder;
    var encoded: [512]u8 = undefined;
    const payload = Encoder.encode(encoded[0..Encoder.calcSize(file_path.len)], file_path);
    const envelope = try std.fmt.bufPrint(
        &self.envelope,
        "\x1b[?2026h\x1b[H\x1b_Ga=T,f=32,s=2,v=1,t=f,i=7,p=1,C=1,q=2;{s}\x1b\\\x1b[?2026l",
        .{payload},
    );
    self.envelope_len = envelope.len;
}

pub fn path(self: *const Frame) []const u8 {
    return self.name_buffer[0..self.name_len];
}
