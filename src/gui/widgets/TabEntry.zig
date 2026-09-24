//! One tab of the strip: its slot in the tabs table and its painted bounds.
const gfx = @import("gfx");
const Rect = gfx.Rect;

index: usize,
bounds: Rect,
