//! Mirrors telar_font_variation: the non-default design coordinates of a
//! variable font's selected instance.
pub const FontVariation = extern struct {
    pub const max_axes = 16;

    count: u32 = 0,
    tags: [max_axes]u32 = @splat(0),
    values: [max_axes]f32 = @splat(0),
};
