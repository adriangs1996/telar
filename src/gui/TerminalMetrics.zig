const cellgrid = @import("cellgrid");
const native = @import("native/native.zig");
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
pub fn measure(self: Metrics, viewport: native.Viewport) !MeasuredGrid {
    if (self.cell_width == 0 or self.cell_height == 0) {
        return error.InvalidCellSize;
    }

    const cols: u64 = @min(viewport.width / self.cell_width, std.math.maxInt(u16));
    var rows: u64 = @min(viewport.height / self.cell_height, std.math.maxInt(u16));
    var measured: MeasuredGrid = .{
        .size = undefined,
    };

    const wanted = @as(u64, viewport.width / self.cell_width) * (viewport.height / self.cell_height);
    if (cols != 0 and cols * rows > core.max_cell_count) {
        rows = core.max_cell_count / cols;
    }

    if (cols * rows < wanted) {
        measured.cut_from = wanted;
    }

    measured.size = .{
        .cols = @intCast(cols),
        .rows = @intCast(rows),
        .cell_width_px = self.cell_width,
        .cell_height_px = self.cell_height,
    };
    try measured.size.validate();
    return measured;
}

test "grid pixels reconstruct the measured cell with remainder outside the grid" {
    const metrics: Metrics = .{ .cell_width = 9, .cell_height = 19, .baseline = 14, .pixel_height = 16 };
    const size = (try metrics.measure(.{ .width = 803, .height = 481, .scale = 1 })).size;
    try std.testing.expectEqual(@as(u16, 89), size.cols);
    try std.testing.expectEqual(@as(u16, 25), size.rows);
    try std.testing.expectEqual(@as(u32, 801), @as(u32, size.cols) * size.cell_width_px);
    try std.testing.expectError(error.InvalidTerminalSize, metrics.measure(.{ .width = 0, .height = 0, .scale = 1 }));
}

test "a viewport past the protocol's cell count keeps its columns and the rows that fit" {
    const metrics: Metrics = .{ .cell_width = 8, .cell_height = 17, .baseline = 13, .pixel_height = 15 };
    const eight_k = try metrics.measure(.{ .width = 7680, .height = 2160, .scale = 1 });
    try std.testing.expectEqual(@as(u16, 960), eight_k.size.cols);
    try std.testing.expectEqual(@as(u16, 127), eight_k.size.rows);
    try std.testing.expectEqual(@as(?u64, null), eight_k.cut_from);

    const tiny: Metrics = .{ .cell_width = 1, .cell_height = 1, .baseline = 1, .pixel_height = 1 };
    const cut = try tiny.measure(.{ .width = 1000, .height = 1000, .scale = 1 });
    try std.testing.expectEqual(@as(u16, 1000), cut.size.cols);
    try std.testing.expectEqual(@as(u16, @intCast(core.max_cell_count / 1000)), cut.size.rows);
    try std.testing.expect(@as(u64, cut.size.cols) * cut.size.rows <= core.max_cell_count);
    try std.testing.expectEqual(@as(?u64, 1_000_000), cut.cut_from);

    const wide = try tiny.measure(.{ .width = 70000, .height = 3, .scale = 1 });
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), wide.size.cols);
    try std.testing.expectEqual(@as(u16, 1), wide.size.rows);
    try std.testing.expectEqual(@as(?u64, 210_000), wide.cut_from);
}
