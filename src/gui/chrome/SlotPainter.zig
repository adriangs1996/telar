//! Paints one Lua-configured bar slot in cells, or in a cell row lent to a
//! pixel band through `LentRow`. The `tabs` slot is empty here because tabs
//! live in their own strip.
const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const LentRow = @import("LentRow.zig");
const BarContent = @import("BarContent.zig");
const MetricsLabel = @import("MetricsLabel.zig");
const SlotPainter = @This();

context: *Context,

/// Measures one slot in cells for the caller's own layout.
/// Example: `const right_width = painter.width(&layout.top_right);`
pub fn width(painter: SlotPainter, slot: *const client.Slot) u16 {
    return switch (slot.*) {
        .empty, .tabs => 0,
        .metrics => MetricsLabel.init(painter.context.projection.system_metrics).width(),
        .content => |*content| content.width(),
    };
}

/// `width` in device pixels, for a pixel band's layout.
/// Example: `const wanted = painter.pixelWidth(&layout.top_right);`
pub fn pixelWidth(painter: SlotPainter, slot: *const client.Slot) f32 {
    return @floatFromInt(@as(u32, painter.width(slot)) * painter.context.canvas.metrics.cell_width);
}

/// Paints one slot clipped to the supplied cell area.
/// Example: `try painter.paint(right_area, &layout.top_right);`
pub fn paint(painter: SlotPainter, area: core.Rect, slot: *const client.Slot) !void {
    switch (slot.*) {
        .empty, .tabs => {},
        .metrics => {
            const label = MetricsLabel.init(painter.context.projection.system_metrics);
            try painter.context.label(area, label.text());
        },
        .content => |*content| {
            const content_painter: BarContent = .{ .context = painter.context, .content = content };
            try content_painter.paint(area);
        },
    }
}

/// `paint` over a pixel band: lends the band one cell row centred in it.
/// Example: `try painter.paintIn(bounds, &layout.top_right);`
pub fn paintIn(painter: SlotPainter, bounds: Rect, slot: *const client.Slot) !void {
    var lent: LentRow = undefined;
    if (!lent.open(painter.context, bounds)) {
        return;
    }

    const lent_painter: SlotPainter = .{ .context = &lent.context };
    try lent_painter.paint(lent.area, slot);
}
