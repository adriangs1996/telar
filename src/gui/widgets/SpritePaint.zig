//! A sprite's identity and its presentation tint, independent of the page.
const core = @import("telar-core");
const Sprite = @import("../image/Sprite.zig");

sprite: Sprite,
color: core.Color = .default,
alpha: f32 = 1,
