//! Lays three Lua-configured bar slots left, centre and right in one cell
//! row lent to the status bar's pixel band through `paintIn`.
const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const LentRow = @import("LentRow.zig");
const SlotPainter = @import("SlotPainter.zig");
const bar_regions = @import("bar_regions.zig");
const SlotRow = @This();

context: *Context,
slots: *const [3]client.Slot,

/// Paints the three slots inside one chrome cell row. A slot that paints
/// nothing gives its space to the custom slots so they share the row.
/// Example: `try row.paint(lent.area);`
pub fn paint(row: SlotRow, area: core.Rect) !void {
    const painter: SlotPainter = .{ .context = row.context };
    var desired: [3]u16 = @splat(0);
    for (row.slots, 0..) |*slot, index| {
        desired[index] = painter.width(slot);
    }

    const regions = bar_regions.calculate(area, desired, row.priorityIndex());
    for (row.slots, regions) |*slot, region| {
        try painter.paint(region, slot);
    }
}

/// `paint` over a pixel band: lends the band one cell row centred in it.
/// Example: `try row.paintIn(bands.status_bar);`
pub fn paintIn(row: SlotRow, bounds: Rect) !void {
    var lent: LentRow = undefined;
    if (!lent.open(row.context, bounds)) {
        return;
    }

    const lent_row: SlotRow = .{ .context = &lent.context, .slots = row.slots };
    try lent_row.paint(lent.area);
}

// The slot that paints nothing takes the region `bar_regions` reserves for
// tabs, so its zero width leaves the whole row to the custom slots.
fn priorityIndex(row: SlotRow) usize {
    for (row.slots, 0..) |slot, index| {
        if (slot == .tabs or slot == .empty) {
            return index;
        }
    }

    return 2;
}
