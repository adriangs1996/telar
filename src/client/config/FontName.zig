const std = @import("std");
const FontName = @This();

bytes: [256:0]u8 = @splat(0),
len: u16 = 0,

/// Owns a validated font family or style name. Empty selects the default.
/// Example: `try family.set("Iosevka Term");`
pub fn set(self: *FontName, text: []const u8) !void {
    if (text.len > self.bytes.len or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) {
        return error.InvalidFontName;
    }

    self.* = .{};
    @memcpy(self.bytes[0..text.len], text);
    self.len = @intCast(text.len);
}

pub fn name(self: *const FontName) [:0]const u8 {
    return self.bytes[0..self.len :0];
}
