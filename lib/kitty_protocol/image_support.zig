//! Image metadata carried by Kitty graphics transmission commands.

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
};
