//! Measured table columns and wrapped cells share the message text painter.
const std = @import("std");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const Table = @import("MessageTable.zig");
const Blocks = @import("MessageBlocks.zig");
const Paint = @This();

bounds: Rect,
viewport: Rect,
table: Table,
owner: ?@import("MessageLayoutOwner.zig") = null,
source_start: usize,
muted: bool = false,

/// Uses bounded column storage and publishes geometry only for visible cells.
/// Example: `const height = try table.layout(canvas, true);`
pub fn layout(widget: Paint, canvas: *Canvas, paint: bool) !f32 {
    var widths: [Table.max_columns]f32 = @splat(0);
    var row = @import("MessageTableRowPaint.zig"){ .table = widget, .canvas = canvas, .widths = &widths };
    try row.measureWidths(widget.table.header, true);
    var lines: Blocks = .{ .text = widget.table.body, .markdown = false };
    while (lines.next()) |line| {
        try row.measureWidths(line.text, false);
    }

    fitWidths(widths[0..widget.table.columns], @max(1, widget.bounds.width), canvas.chrome.px(72));
    row.y = widget.bounds.y + canvas.chrome.px(6);
    try row.layout(widget.table.header, .{ .header = true, .paint = paint });
    lines = .{ .text = widget.table.body, .markdown = false };
    while (lines.next()) |line| {
        try row.layout(line.text, .{ .paint = paint });
    }

    return row.y - widget.bounds.y + canvas.chrome.px(10);
}

fn fitWidths(widths: []f32, available: f32, minimum: f32) void {
    const count: f32 = @floatFromInt(widths.len);
    const floor = @min(minimum, available / count);
    var extra: f32 = 0;
    for (widths) |width| {
        extra += @max(0, width - floor);
    }

    const room = @max(0, available - floor * count);
    for (widths) |*width| {
        width.* = floor + if (extra > 0) room * @max(0, width.* - floor) / extra else room / count;
    }
}

test "table columns fit both narrow and wide viewports without negative widths" {
    for ([_]f32{ 1, 90, 360, 1200 }) |available| {
        var widths = [_]f32{ 100, 240, 480 };
        fitWidths(&widths, available, 72);
        var total: f32 = 0;
        for (widths) |width| {
            try std.testing.expect(width > 0);
            total += width;
        }

        try std.testing.expectApproxEqAbs(available, total, 0.001);
        try std.testing.expect(widths[2] >= widths[1] and widths[1] >= widths[0]);
    }
}
