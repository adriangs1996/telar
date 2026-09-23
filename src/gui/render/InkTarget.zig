//! Where retained ink lands this frame: its pane clip and the block cursor's
//! text color when the cell sits under it.
const Color = @import("Color.zig");
const Rect = @import("Rect.zig");

bounds: Rect,
color: ?Color = null,
