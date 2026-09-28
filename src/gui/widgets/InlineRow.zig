//! One inline component drawn on its own line of a panel.
const data = @import("model");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const InlineRow = @This();

index: usize,
bounds: Rect,
facts: *const data.BarFacts,
