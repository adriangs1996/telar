//! Where retained ink lands this frame: its pane clip and the block cursor's
//! text color when the cell sits under it.
const gfx = @import("gfx");
const Color = gfx.Color;
const Rect = gfx.Rect;

bounds: Rect,
color: ?Color = null,
