//! Lays three Lua-configured bar slots left, centre and right in one cell
//! row lent to the status bar's pixel band.
const data = @import("model");
const Canvas = @import("Canvas.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const LentRow = @import("LentRow.zig");
const SlotPainter = @import("SlotPainter.zig");
const bar_regions = @import("bar_regions.zig");
const SlotRow = @This();

slots: *const [3]data.bar_values.Slot,
area: Rect,
metrics: ?data.SystemMetrics = null,

/// Paints the three slots inside one chrome cell row. A slot that paints
/// nothing gives its space to the custom slots so they share the row.
/// Example: `try row.draw(canvas);`
pub fn draw(self: SlotRow, canvas: *Canvas) !void {
    const first = canvas.quads.items().len;
    defer canvas.quads.clipFrom(first, self.area);
    var lent: LentRow = undefined;
    if (!lent.open(canvas, self.area)) {
        return;
    }

    var desired: [3]u16 = @splat(0);
    for (self.slots, 0..) |*slot, index| {
        const painter: SlotPainter = .{ .slot = slot, .metrics = self.metrics };
        desired[index] = painter.width();
    }

    const regions = bar_regions.calculate(lent.area, desired, self.priorityIndex());
    for (self.slots, regions) |*slot, region| {
        const painter: SlotPainter = .{ .slot = slot, .area = region, .metrics = self.metrics };
        try painter.draw(&lent.canvas);
    }
}

// The slot that paints nothing takes the region `bar_regions` reserves for
// tabs, so its zero width leaves the whole row to the custom slots.
fn priorityIndex(self: SlotRow) usize {
    for (self.slots, 0..) |slot, index| {
        if (slot == .tabs or slot == .empty) {
            return index;
        }
    }

    return 2;
}
