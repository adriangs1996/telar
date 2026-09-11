//! Image metadata carried by Kitty graphics transmission commands.

pub const Format = enum(u8) {
    rgb = 24,
    rgba = 32,
};

pub const Image = @import("Image.zig");
