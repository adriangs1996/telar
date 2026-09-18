//! A smooth spatial highlight over already-shaped glyphs.
const Wave = @This();

center: f32,
radius: f32,
minimum: f32 = 0.52,

/// Example: `glyph.a *= wave.at(glyph.x + glyph.width / 2);`
pub fn at(wave: Wave, x: f32) f32 {
    const distance = @min(1, @abs(x - wave.center) / @max(1, wave.radius));
    const weight = 1 - distance;
    return wave.minimum + (1 - wave.minimum) * weight * weight * (3 - 2 * weight);
}
