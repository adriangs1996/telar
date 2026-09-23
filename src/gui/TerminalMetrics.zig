const native = @import("native/native.zig");
const std = @import("std");
const core = @import("telar-core");
const Metrics = @This();

cell_width: u16,
cell_height: u16,
baseline: f32,
pixel_height: u16,

/// Maps host grid coordinates into physical pixels with an external inset.
/// Example: `const pixels = metrics.rect(.{ 8, 12 }, pane.content);`
pub fn rect(self: Metrics, origin: [2]u32, cells: core.Rect) @import("render/Rect.zig") {
    return .{
        .x = @floatFromInt(origin[0] + @as(u32, cells.x) * self.cell_width),
        .y = @floatFromInt(origin[1] + @as(u32, cells.y) * self.cell_height),
        .width = @floatFromInt(@as(u32, cells.w) * self.cell_width),
        .height = @floatFromInt(@as(u32, cells.h) * self.cell_height),
    };
}

/// Supplies fallback fitting with the actual grid rather than natural font metrics.
/// Example: `run.cell_bounds = metrics.glyphCell();`
pub fn glyphCell(self: Metrics) @import("render/Rect.zig") {
    return .{ .x = 0, .y = -self.baseline, .width = @floatFromInt(self.cell_width), .height = @floatFromInt(self.cell_height) };
}

/// Computes only complete cells. Edge pixels belong to the native chrome.
/// Example: `const size = try metrics.measure(viewport);`
pub fn measure(self: Metrics, viewport: native.Viewport) !core.TerminalSize {
    if (self.cell_width == 0 or self.cell_height == 0) {
        return error.InvalidCellSize;
    }

    const size: core.TerminalSize = .{
        .cols = std.math.cast(u16, viewport.width / self.cell_width) orelse return error.ScreenTooLarge,
        .rows = std.math.cast(u16, viewport.height / self.cell_height) orelse return error.ScreenTooLarge,
        .cell_width_px = self.cell_width,
        .cell_height_px = self.cell_height,
    };
    try size.validate();
    return size;
}

test "grid pixels reconstruct the measured cell with remainder outside the grid" {
    const metrics: Metrics = .{ .cell_width = 9, .cell_height = 19, .baseline = 14, .pixel_height = 16 };
    const size = try metrics.measure(.{ .width = 803, .height = 481, .scale = 1 });
    try std.testing.expectEqual(@as(u16, 89), size.cols);
    try std.testing.expectEqual(@as(u16, 25), size.rows);
    try std.testing.expectEqual(@as(u32, 801), @as(u32, size.cols) * size.cell_width_px);
    try std.testing.expectError(error.InvalidTerminalSize, metrics.measure(.{ .width = 0, .height = 0, .scale = 1 }));
}
