//! Synchronous row layout. The tallest wrapped cell determines the row height.
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const Flow = @import("MessageTextFlow.zig");
const Row = @This();

table: @import("MessageTablePaint.zig"),
canvas: *Canvas,
widths: *[@import("MessageTable.zig").max_columns]f32,
y: f32 = 0,

/// Caps preferred widths so a long URL cannot claim the whole table.
/// Example: `try row.measureWidths(header, true);`
pub fn measureWidths(row: Row, text: []const u8, header: bool) !void {
    var cells = row.table.table.rowCells(text);
    for (row.widths[0..row.table.table.columns]) |*width| {
        const cell = cells.next() orelse break;
        var flow = row.makeFlow(.{ .x = 0, .y = 0, .width = row.canvas.chrome.px(480), .height = 0 }, false);
        try flow.appendStyled(cell, .{ .text = "", .size = .body, .bold = header });
        width.* = @max(width.*, flow.max_x + row.canvas.chrome.px(24));
    }
}

/// Measures before painting backgrounds, links and selectable cell text.
/// Example: `try row.layout(text, .{ .header = true, .paint = true });`
pub fn layout(row: *Row, text: []const u8, options: @import("MessageTableRowOptions.zig")) !void {
    var cells = row.table.table.rowCells(text);
    var height: f32 = row.canvas.chrome.px(25);
    const padding = row.canvas.chrome.px(9);
    var alignments: [@import("MessageTable.zig").max_columns]@import("MessageTextAlignment.zig") = undefined;
    var x = row.table.bounds.x;
    for (row.widths[0..row.table.table.columns], 0..) |width, column| {
        const cell = cells.next() orelse "";
        var flow = row.makeFlow(row.cellBounds(x, width), false);
        alignments[column] = .{ .kind = row.table.table.alignments[column], .first_row = @intFromFloat(@max(0, @floor((row.table.viewport.y - flow.bounds.y) / flow.row))) };
        flow.alignment = &alignments[column];
        try flow.appendStyled(cell, .{ .text = "", .size = .body, .bold = options.header });
        height = @max(height, flow.height());
        x += width;
    }

    height += 2 * padding;
    defer row.y += height;
    if (!options.paint or row.y >= row.table.viewport.y + row.table.viewport.height or row.y + height <= row.table.viewport.y) {
        return;
    }

    const area: Rect = .{ .x = row.table.bounds.x, .y = row.y, .width = row.table.bounds.width, .height = height };
    if (options.header) {
        try row.canvas.fillAt(area, row.canvas.theme.palette.surface0);
    }

    const border = row.canvas.theme.palette.surface1;
    try row.canvas.fillAt(.{ .x = area.x, .y = area.y + height - 1, .width = area.width, .height = 1 }, border);
    if (options.header) {
        try row.canvas.fillAt(.{ .x = area.x, .y = area.y, .width = area.width, .height = 1 }, border);
    }

    cells = row.table.table.rowCells(text);
    x = area.x;
    for (row.widths[0..row.table.table.columns], 0..) |width, column| {
        try row.canvas.fillAt(.{ .x = x, .y = area.y, .width = @min(1, width), .height = height }, border);
        const cell = cells.next() orelse "";
        const bounds = row.cellBounds(x, width);
        var flow = row.makeFlow(bounds, true);
        flow.alignment = &alignments[column];
        const first = row.canvas.quads.items().len;
        try flow.appendStyled(cell, .{ .text = "", .size = .body, .bold = options.header, .color = if (row.table.muted) row.canvas.theme.palette.subtext0 else row.canvas.theme.palette.text });
        row.canvas.quads.clipFrom(first, flow.viewport);
        x += width;
    }

    try row.canvas.fillAt(.{ .x = area.x + @max(0, area.width - 1), .y = area.y, .width = @min(1, area.width), .height = height }, border);
}

fn cellBounds(row: Row, x: f32, width: f32) Rect {
    const inset = @min(row.canvas.chrome.px(12), width / 4);
    return .{ .x = x + inset, .y = row.y + row.canvas.chrome.px(9), .width = @max(0.01, width - 2 * inset), .height = 0 };
}

fn makeFlow(row: Row, bounds: Rect, paint: bool) Flow {
    const viewport = row.table.viewport;
    const left = @max(viewport.x, bounds.x);
    const right = @min(viewport.x + viewport.width, bounds.x + bounds.width);
    return .{ .canvas = row.canvas, .bounds = bounds, .viewport = .{ .x = left, .y = viewport.y, .width = @max(0, right - left), .height = viewport.height }, .row = row.canvas.chrome.px(25), .paint = paint, .owner = row.table.owner, .source_start = row.table.source_start, .table_cell = true };
}
