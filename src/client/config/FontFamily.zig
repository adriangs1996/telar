const std = @import("std");
const FontFamily = @This();

bytes: [256:0]u8 = @splat(0),
len: u16 = 0,

/// Owns a validated system font name. Empty selects the bundled face.
/// Example: `try family.set("Iosevka Term");`
pub fn set(self: *FontFamily, text: []const u8) !void {
    if (text.len > self.bytes.len or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) {
        return error.InvalidFontFamily;
    }

    self.* = .{};
    @memcpy(self.bytes[0..text.len], text);
    self.len = @intCast(text.len);
}

pub fn name(self: *const FontFamily) [:0]const u8 {
    return self.bytes[0..self.len :0];
}
