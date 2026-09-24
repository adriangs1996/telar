//! One configured bar slot in a cell row supplied by its parent's canvas.
//! Tabs have their own widget and leave this slot empty.
const cellgrid = @import("cellgrid");
const data = @import("model");
const Canvas = @import("Canvas.zig");
const BarContent = @import("BarContent.zig");
const MetricsLabel = @import("MetricsLabel.zig");
const SlotPainter = @This();

slot: *const data.bar_values.Slot,
area: cellgrid.Rect = .{},
metrics: ?data.SystemMetrics = null,

/// Measures one slot in cells for the caller's own layout.
/// Example: `const right_width = painter.width();`
pub fn width(self: SlotPainter) u16 {
    return switch (self.slot.*) {
        .empty, .tabs => 0,
        .metrics => MetricsLabel.init(self.metrics).width(),
        .content => |*content| BarContent.columns(content),
    };
}

/// `width` in device pixels, for a pixel band's layout.
/// Example: `const wanted = painter.pixelWidth(canvas);`
pub fn pixelWidth(self: SlotPainter, canvas: *const Canvas) f32 {
    return @floatFromInt(@as(u32, self.width()) * canvas.metrics.cell_width);
}

/// Paints one slot clipped to the supplied cell area.
/// Example: `try painter.draw(canvas);`
pub fn draw(self: SlotPainter, canvas: *Canvas) !void {
    switch (self.slot.*) {
        .empty, .tabs => {},
        .metrics => {
            const label = MetricsLabel.init(self.metrics);
            try canvas.text(self.area, .{ .text = label.text(), .color = canvas.theme.palette.subtext0 });
        },
        .content => |*content| {
            const content_widget: BarContent = .{ .content = content, .area = self.area };
            try content_widget.draw(canvas);
        },
    }
}
