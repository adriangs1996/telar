const std = @import("std");
const Char = @This();

bytes: [4]u8 = @splat(0),
len: u8 = 0,

/// Copies one decoded UTF-8 scalar into the event. Example: const c = Char.init("ñ");
pub fn init(text: []const u8) Char {
    var char: Char = .{
        .len = @intCast(@min(text.len, 4)),
    };
    @memcpy(char.bytes[0..char.len], text[0..char.len]);
    return char;
}

pub fn slice(self: *const Char) []const u8 {
    return self.bytes[0..self.len];
}

pub fn eql(self: *const Char, text: []const u8) bool {
    return std.mem.eql(
        u8,
        self.slice(),
        text,
    );
}
