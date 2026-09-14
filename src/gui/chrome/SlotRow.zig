//! Paints a Lua-configured bar slot inside a pixel band by lending it one
//! virtual cell row centred in the band. The slot painters keep their cell
//! interface; only the origin moves, so no slot code is duplicated here.
//! The `tabs` slot is empty: tabs live in their own strip now.
const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const BarContent = @import("BarContent.zig");
const MetricsLabel = @import("MetricsLabel.zig");
const SlotRow = @This();

context: *Context,

/// Pixel width the slot wants, measured in whole cells.
/// Example: `const wanted = slot_row.width(&layout.top_right);`
pub fn width(row: SlotRow, slot: *const client.Slot) f32 {
    const columns: u32 = switch (slot.*) {
        .empty, .tabs => 0,
        .metrics => MetricsLabel.init(row.context.projection.system_metrics).width(),
        .content => |*content| content.width(),
    };
    return @floatFromInt(columns * row.context.canvas.metrics.cell_width);
}

/// Paints the slot in a cell row placed over `bounds`.
/// Example: `try slot_row.paint(bounds, &layout.bottom[0]);`
pub fn paint(row: SlotRow, bounds: Rect, slot: *const client.Slot) !void {
    const metrics = row.context.canvas.metrics;
    if (bounds.width < @as(f32, @floatFromInt(metrics.cell_width)) or bounds.height <= 0) {
        return;
    }

    var canvas = row.context.canvas.*;
    canvas.origin = .{ @intFromFloat(@max(0, bounds.x)), @intFromFloat(@max(0, bounds.y + @floor((bounds.height - @as(f32, @floatFromInt(metrics.cell_height))) / 2))) };
    var context = row.context.*;
    context.canvas = &canvas;
    const area: core.Rect = .{ .w = @intCast(@min(65535, @as(u32, @intFromFloat(bounds.width / @as(f32, @floatFromInt(metrics.cell_width)))))), .h = 1 };
    switch (slot.*) {
        .empty, .tabs => {},
        .metrics => {
            const label = MetricsLabel.init(context.projection.system_metrics);
            try context.label(area, label.text());
        },
        .content => |*content| {
            const painter: BarContent = .{ .context = &context, .content = content };
            try painter.paint(area);
        },
    }
}
