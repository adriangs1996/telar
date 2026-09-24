//! Image metadata carried by Kitty graphics transmission commands.
const std = @import("std");

/// Pixel format, valued as the `f=` key sends it.
pub const Format = enum(u8) {
    rgb = 24,
    rgba = 32,

    /// Bytes one pixel of this format takes.
    ///
    /// ```zig
    /// const len = width * height * format.bytesPerPixel();
    /// ```
    pub fn bytesPerPixel(self: Format) usize {
        return switch (self) {
            .rgb => 3,
            .rgba => 4,
        };
    }

    /// The format an `f=` value names; other depths are not raw pixels.
    ///
    /// ```zig
    /// format = Format.parse(field.value) orelse return null;
    /// ```
    pub fn parse(value: []const u8) ?Format {
        const depth = std.fmt.parseUnsigned(u8, value, 10) catch return null;
        return std.enums.fromInt(Format, depth);
    }

    /// Bytes of a `width` by `height` image, or null when it overflows.
    ///
    /// ```zig
    /// const byte_len = format.byteLen(width, height) orelse return null;
    /// ```
    pub fn byteLen(self: Format, width: u32, height: u32) ?usize {
        const pixels = std.math.mul(usize, width, height) catch return null;
        return std.math.mul(usize, pixels, self.bytesPerPixel()) catch null;
    }
};

test "formats parse only raw pixel depths and size without overflow" {
    try std.testing.expectEqual(@as(?Format, .rgb), Format.parse("24"));
    try std.testing.expectEqual(@as(?Format, .rgba), Format.parse("32"));
    try std.testing.expect(Format.parse("100") == null);
    try std.testing.expect(Format.parse("x") == null);
    try std.testing.expectEqual(@as(?usize, 12), Format.rgb.byteLen(2, 2));
}
