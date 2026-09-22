//! A stroke drawn inside an area's outline, optionally rounded. It leaves the
//! interior untouched, so it can mark attention over a pane or a card.
const core = @import("telar-core");
width: f32,
color: core.Color,
radius: f32 = 0,
/// Opacity of the stroke, so a ring can fade in over animation frames.
alpha: f32 = 1,
