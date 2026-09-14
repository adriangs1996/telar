//! A stroke drawn inside an area's outline, optionally rounded. It leaves the
//! interior untouched, so it can mark attention over a pane or a card.
width: f32,
color: @import("telar-core").Color,
radius: f32 = 0,
