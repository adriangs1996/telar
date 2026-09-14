//! One cell row lent to a pixel band: a copy of the canvas whose origin is
//! the row centred in the band, with a context that paints through it. Cell
//! painters keep their interface; only the origin moves. The caller owns the
//! storage so the borrowed context stays valid while it paints.
const core = @import("telar-core");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const LentRow = @This();

canvas: Canvas,
context: Context,
/// The lent row in the lent canvas's own grid: `x = 0`, `y = 0`, one row.
area: core.Rect,

/// Places the row over `bounds`; false when the band holds no whole cell.
/// Example:
/// ```
/// var lent: LentRow = undefined;
/// if (lent.open(context, band)) {
///     try slot_row.paintWith(&lent.context, lent.area);
/// }
/// ```
pub fn open(lent: *LentRow, context: *const Context, bounds: Rect) bool {
    const metrics = context.canvas.metrics;
    const cell_width: f32 = @floatFromInt(metrics.cell_width);
    const cell_height: f32 = @floatFromInt(metrics.cell_height);
    if (bounds.width < cell_width or bounds.height <= 0) {
        return false;
    }

    lent.canvas = context.canvas.*;
    lent.canvas.origin = .{ @intFromFloat(@max(0, bounds.x)), @intFromFloat(@max(0, bounds.y + @floor((bounds.height - cell_height) / 2))) };
    lent.context = context.*;
    lent.context.canvas = &lent.canvas;
    lent.area = .{ .w = @intCast(@min(65535, @as(u32, @intFromFloat(bounds.width / cell_width)))), .h = 1 };
    return true;
}
