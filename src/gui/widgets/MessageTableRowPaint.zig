//! Synchronous row layout. The tallest wrapped cell determines the row height.
const MessageTable = @import("MessageTable.zig");
const Canvas = @import("Canvas.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Flow = @import("MessageTextFlow.zig");
const MessageTablePaint = @import("MessageTablePaint.zig");
const MessageTableRowOptions = @import("MessageTableRowOptions.zig");
const MessageTextAlignment = @import("MessageTextAlignment.zig");
const Row = @This();

table: MessageTablePaint,
canvas: *Canvas,
widths: *[MessageTable.max_columns]f32,
y: f32 = 0,

/// Caps preferred widths so a long URL cannot claim the whole table.
/// Example: `try row.measureWidths(header, true);`
pub fn measureWidths(self: Row, text: []const u8, header: bool) !void {
    var cells = self.table.table.rowCells(text);
    for (self.widths[0..self.table.table.columns]) |*width| {
        const cell = cells.next() orelse break;
        var flow = self.makeFlow(.{ .x = 0, .y = 0, .width = self.canvas.chrome.px(480), .height = 0 }, false);
        try flow.appendStyled(cell, .{ .text = "", .size = .body, .bold = header });
        width.* = @max(width.*, flow.max_x + self.canvas.chrome.px(24));
    }
}

/// Measures before painting backgrounds, links and selectable cell text.
/// Example: `try row.layout(text, .{ .header = true, .paint = true });`
pub fn layout(self: *Row, text: []const u8, options: MessageTableRowOptions) !void {
    var cells = self.table.table.rowCells(text);
    var height: f32 = self.canvas.chrome.px(25);
    const padding = self.canvas.chrome.px(9);
    var alignments: [MessageTable.max_columns]MessageTextAlignment = undefined;
    var x = self.table.bounds.x;
    for (self.widths[0..self.table.table.columns], 0..) |width, column| {
        const cell = cells.next() orelse "";
        var flow = self.makeFlow(self.cellBounds(x, width), false);
        alignments[column] = .{ .kind = self.table.table.alignments[column], .first_row = @intFromFloat(@max(0, @floor((self.table.viewport.y - flow.bounds.y) / flow.row))) };
        flow.alignment = &alignments[column];
        try flow.appendStyled(cell, .{ .text = "", .size = .body, .bold = options.header });
        height = @max(height, flow.height());
        x += width;
    }

    height += 2 * padding;
    defer self.y += height;
    if (!options.paint or self.y >= self.table.viewport.y + self.table.viewport.height or self.y + height <= self.table.viewport.y) {
        return;
    }

    const area: Rect = .{ .x = self.table.bounds.x, .y = self.y, .width = self.table.bounds.width, .height = height };
    if (options.header) {
        try self.canvas.fillAt(area, self.canvas.theme.palette.surface0);
    }

    const border = self.canvas.theme.palette.surface1;
    try self.canvas.fillAt(.{ .x = area.x, .y = area.y + height - 1, .width = area.width, .height = 1 }, border);
    if (options.header) {
        try self.canvas.fillAt(.{ .x = area.x, .y = area.y, .width = area.width, .height = 1 }, border);
    }

    cells = self.table.table.rowCells(text);
    x = area.x;
    for (self.widths[0..self.table.table.columns], 0..) |width, column| {
        try self.canvas.fillAt(.{ .x = x, .y = area.y, .width = @min(1, width), .height = height }, border);
        const cell = cells.next() orelse "";
        const bounds = self.cellBounds(x, width);
        var flow = self.makeFlow(bounds, true);
        flow.alignment = &alignments[column];
        const first = self.canvas.quads.items().len;
        try flow.appendStyled(cell, .{ .text = "", .size = .body, .bold = options.header, .color = if (self.table.muted) self.canvas.theme.palette.subtext0 else self.canvas.theme.palette.text });
        self.canvas.quads.clipFrom(first, flow.viewport);
        x += width;
    }

    try self.canvas.fillAt(.{ .x = area.x + @max(0, area.width - 1), .y = area.y, .width = @min(1, area.width), .height = height }, border);
}

fn cellBounds(self: Row, x: f32, width: f32) Rect {
    const inset = @min(self.canvas.chrome.px(12), width / 4);
    return .{ .x = x + inset, .y = self.y + self.canvas.chrome.px(9), .width = @max(0.01, width - 2 * inset), .height = 0 };
}

fn makeFlow(self: Row, bounds: Rect, paint: bool) Flow {
    const viewport = self.table.viewport;
    const left = @max(viewport.x, bounds.x);
    const right = @min(viewport.x + viewport.width, bounds.x + bounds.width);
    return .{ .canvas = self.canvas, .bounds = bounds, .viewport = .{ .x = left, .y = viewport.y, .width = @max(0, right - left), .height = viewport.height }, .row = self.canvas.chrome.px(25), .paint = paint, .owner = self.table.owner, .source_start = self.table.source_start, .table_cell = true };
}
