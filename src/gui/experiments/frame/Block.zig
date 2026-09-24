const gfx = @import("gfx");
const quad = gfx.Quad;

id: u64,
/// Must change whenever ANY quad byte changes, including visual invalidation.
revision: u64,
quads: []const quad.Quad,
