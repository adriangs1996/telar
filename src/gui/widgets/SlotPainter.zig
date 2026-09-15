//! One configured bar slot in a cell row supplied by its parent's canvas.
//! Tabs have their own widget and leave this slot empty.
const core = @import("telar-core");
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const BarContent = @import("BarContent.zig");
const MetricsLabel = @import("MetricsLabel.zig");
const SlotPainter = @This();

slot: *const client.Slot,
area: core.Rect = .{},
metrics: ?client.SystemMetrics = null,

/// Measures one slot in cells for the caller's own layout.
/// Example: `const right_width = painter.width();`
pub fn width(painter: SlotPainter) u16 {
    return switch (painter.slot.*) {
        .empty, .tabs => 0,
        .metrics => MetricsLabel.init(painter.metrics).width(),
        .content => |*content| BarContent.columns(content),
    };
}

/// `width` in device pixels, for a pixel band's layout.
/// Example: `const wanted = painter.pixelWidth(canvas);`
pub fn pixelWidth(painter: SlotPainter, canvas: *const Canvas) f32 {
    return @floatFromInt(@as(u32, painter.width()) * canvas.metrics.cell_width);
}

/// Paints one slot clipped to the supplied cell area.
/// Example: `try painter.draw(canvas);`
pub fn draw(painter: SlotPainter, canvas: *Canvas) !void {
    switch (painter.slot.*) {
        .empty, .tabs => {},
        .metrics => {
            const label = MetricsLabel.init(painter.metrics);
            try canvas.text(painter.area, .{ .text = label.text(), .color = canvas.theme.palette.subtext0 });
        },
        .content => |*content| {
            const content_widget: BarContent = .{ .content = content, .area = painter.area };
            try content_widget.draw(canvas);
        },
    }
}
