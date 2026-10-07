const cellgrid = @import("cellgrid");
const Window = @import("telar-window");
const std = @import("std");
const core = @import("telar-core");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const MeasuredGrid = @import("MeasuredGrid.zig");
const Metrics = @This();

cell_width: u16,
cell_height: u16,
baseline: f32,
pixel_height: u16,

/// Maps host grid coordinates into physical pixels with an external inset.
/// Example: `const pixels = metrics.rect(.{ 8, 12 }, pane.content);`
pub fn rect(self: Metrics, origin: [2]u32, cells: cellgrid.Rect) Rect {
    return .{
        .x = @floatFromInt(origin[0] + @as(u32, cells.x) * self.cell_width),
        .y = @floatFromInt(origin[1] + @as(u32, cells.y) * self.cell_height),
        .width = @floatFromInt(@as(u32, cells.w) * self.cell_width),
        .height = @floatFromInt(@as(u32, cells.h) * self.cell_height),
    };
}

/// Supplies fallback fitting with the actual grid rather than natural font metrics.
/// Example: `run.cell_bounds = metrics.glyphCell();`
pub fn glyphCell(self: Metrics) Rect {
    return .{ .x = 0, .y = -self.baseline, .width = @floatFromInt(self.cell_width), .height = @floatFromInt(self.cell_height) };
}

/// Computes only complete cells. Edge pixels belong to the native chrome.
/// A viewport holding more than `core.max_cell_count` cells keeps its
/// columns and as many rows as fit; the rows below stay empty and the cut
/// is returned so the window reports `protocol.max_cell_count`.
/// Example: `const measured = try metrics.measure(viewport);`
pub fn measure(self: Metrics, viewport: Window.Viewport) !MeasuredGrid {
    if (self.cell_width == 0 or self.cell_height == 0) {
        return error.InvalidCellSize;
    }

    const cols: u64 = @min(viewport.width / self.cell_width, std.math.maxInt(u16));
    var rows: u64 = @min(viewport.height / self.cell_height, std.math.maxInt(u16));

    const wanted = @as(u64, viewport.width / self.cell_width) * (viewport.height / self.cell_height);
    if (cols != 0 and cols * rows > core.max_cell_count) {
        rows = core.max_cell_count / cols;
    }

    const measured: MeasuredGrid = .{
        .size = .{
            .cols = @intCast(cols),
            .rows = @intCast(rows),
            .cell_width_px = self.cell_width,
            .cell_height_px = self.cell_height,
        },
        .cut_from = if (cols * rows < wanted) wanted else null,
    };
    try measured.size.validate();
    return measured;
}
