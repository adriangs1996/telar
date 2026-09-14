//! One cell row lent to a pixel band: a copy of the canvas whose origin is
//! the row centred in the band. The caller owns the temporary canvas through
//! its children's synchronous draws.
const core = @import("telar-core");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const LentRow = @This();

canvas: Canvas,
/// The lent row in the lent canvas's own grid: `x = 0`, `y = 0`, one row.
area: core.Rect,

/// Places the row over `bounds`; false when the band holds no whole cell.
/// Example:
/// ```
/// var lent: LentRow = undefined;
/// if (lent.open(canvas, band)) {
///     try slot.draw(&lent.canvas);
/// }
/// ```
pub fn open(lent: *LentRow, canvas: *const Canvas, bounds: Rect) bool {
    const metrics = canvas.metrics;
    const cell_width: f32 = @floatFromInt(metrics.cell_width);
    const cell_height: f32 = @floatFromInt(metrics.cell_height);
    if (bounds.width < cell_width or bounds.height <= 0) {
        return false;
    }

    lent.canvas = canvas.*;
    lent.canvas.origin = .{ @intFromFloat(@max(0, bounds.x)), @intFromFloat(@max(0, bounds.y + @floor((bounds.height - cell_height) / 2))) };
    lent.area = .{ .w = @intCast(@min(65535, @as(u32, @intFromFloat(bounds.width / cell_width)))), .h = 1 };
    return true;
}
