//! A sprite's identity and its presentation tint, independent of the page.
const cellgrid = @import("cellgrid");
const Sprite = @import("../image/Sprite.zig");

sprite: Sprite,
color: cellgrid.Color = .default,
alpha: f32 = 1,
