//! The PLTE entries and optional tRNS alphas of a palette PNG.
const PngPalette = @This();

pub const max_entries = 256;

colors: [max_entries][3]u8 = undefined,
alphas: [max_entries]u8 = @splat(255),
count: u16 = 0,

/// The straight RGBA of one index; out-of-range indices are an error.
/// Example: `const rgba = try palette.lookup(index);`
pub fn lookup(palette: *const PngPalette, index: u8) ![4]u8 {
    if (index >= palette.count) {
        return error.InvalidPngData;
    }

    const color = palette.colors[index];
    return .{ color[0], color[1], color[2], palette.alphas[index] };
}
