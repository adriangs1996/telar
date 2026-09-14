//! A sprite's identity and its presentation tint, independent of the page.
const Sprite = @import("../image/Sprite.zig");
const Color = @import("telar-core").Color;

sprite: Sprite,
color: Color = .default,
alpha: f32 = 1,
