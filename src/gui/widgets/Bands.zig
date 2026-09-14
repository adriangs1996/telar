//! The pixel bands the chrome reserves around the cell grid: the top bar
//! across the window, the sidebar band down the left and the status bar along
//! the bottom. They are derived from the same origin the grid and the
//! pointer use, so a band never overlaps a cell.
const Rect = @import("../render/Rect.zig");
const Canvas = @import("Canvas.zig");
const Bands = @This();

top_bar: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
sidebar: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
status_bar: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

/// Places navigation across the window, independently of sidebar visibility.
/// The sidebar starts below navigation and ends above the status bar.
/// Example: `const bands = Bands.resolve(canvas);`
pub fn resolve(canvas: *const Canvas) Bands {
    const width: f32 = @floatFromInt(canvas.viewport[0]);
    const height: f32 = @floatFromInt(canvas.viewport[1]);
    const top: f32 = @floatFromInt(canvas.chrome.top_bar);
    const status: f32 = @floatFromInt(canvas.chrome.status_bar);
    const body_top = @min(height, top);
    return .{
        .top_bar = .{ .x = 0, .y = 0, .width = width, .height = @min(top, height) },
        .sidebar = .{ .x = 0, .y = body_top, .width = @min(width, @as(f32, @floatFromInt(canvas.sidebar.width))), .height = @max(0, height - status - body_top) },
        .status_bar = .{ .x = 0, .y = @max(0, height - status), .width = width, .height = @min(status, height) },
    };
}

/// Whether a window point lies in any band, in the pointer's coordinates.
/// Example: `if (bands.contains(event.x, event.y)) return chrome.bandPointer(event);`
pub fn contains(bands: Bands, x: f64, y: f64) bool {
    return within(bands.top_bar, x, y) or within(bands.sidebar, x, y) or within(bands.status_bar, x, y);
}

/// Example: `if (Bands.within(bounds, event.x, event.y)) return hit.action;`
pub fn within(bounds: Rect, x: f64, y: f64) bool {
    return x >= bounds.x and y >= bounds.y and x < @as(f64, bounds.x) + bounds.width and y < @as(f64, bounds.y) + bounds.height;
}
