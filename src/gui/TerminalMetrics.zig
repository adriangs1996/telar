const std = @import("std");
const core = @import("telar-core");
const Viewport = @import("native/native.zig").Viewport;
const Metrics = @This();

cell_width: u16,
cell_height: u16,
baseline: f32,
pixel_height: u16,

/// Computes only complete cells. Edge pixels belong to the native chrome.
/// Example: `const size = try metrics.measure(viewport);`
pub fn measure(metrics: Metrics, viewport: Viewport) !core.TerminalSize {
    if (metrics.cell_width == 0 or metrics.cell_height == 0) {
        return error.InvalidCellSize;
    }

    const size: core.TerminalSize = .{
        .cols = std.math.cast(u16, viewport.width / metrics.cell_width) orelse return error.ScreenTooLarge,
        .rows = std.math.cast(u16, viewport.height / metrics.cell_height) orelse return error.ScreenTooLarge,
        .cell_width_px = metrics.cell_width,
        .cell_height_px = metrics.cell_height,
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
