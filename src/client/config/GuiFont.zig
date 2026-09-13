const FontFamily = @import("FontFamily.zig");

family: FontFamily = .{},
size: f32 = 15,
line_height: f32 = 1,
letter_spacing: f32 = 0,
thicken: bool = false,
thicken_strength: u8 = 255,

/// Applies UI proportions to the user's base size in logical pixels.
/// Example: `const heading = font.scaledSize(1.25);`
pub fn scaledSize(font: @This(), ratio: f32) f32 {
    return font.size * ratio;
}
