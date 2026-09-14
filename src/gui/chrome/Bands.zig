//! The pixel bands the chrome reserves around the cell grid: the top bar
//! across the window, the tab strip over the workbench with its shoulder
//! over the sidebar, and the status bar along the bottom. They are derived
//! from the same origin the grid and the pointer use, so a band never
//! overlaps a cell.
const Rect = @import("../render/Rect.zig");
const core = @import("telar-core");
const Canvas = @import("Canvas.zig");
const Bands = @This();

top_bar: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
shoulder: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
tab_strip: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
status_bar: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

/// Places the bands for one canvas; the tab strip starts at the workbench's
/// first cell and runs to the window edge, so trailing pixels stay chrome.
/// Example: `const bands = Bands.resolve(canvas, regions.workbench);`
pub fn resolve(canvas: *const Canvas, workbench: core.Rect) Bands {
    const width: f32 = @floatFromInt(canvas.viewport[0]);
    const height: f32 = @floatFromInt(canvas.viewport[1]);
    const top: f32 = @floatFromInt(canvas.chrome.top_bar);
    const strip: f32 = @floatFromInt(canvas.chrome.tab_strip);
    const status: f32 = @floatFromInt(canvas.chrome.status_bar);
    const workbench_x = if (workbench.isEmpty()) @as(f32, @floatFromInt(canvas.origin[0])) else canvas.rect(workbench).x;
    const split = @min(width, workbench_x);
    return .{
        .top_bar = .{ .x = 0, .y = 0, .width = width, .height = @min(top, height) },
        .shoulder = .{ .x = 0, .y = top, .width = split, .height = strip },
        .tab_strip = .{ .x = split, .y = top, .width = width - split, .height = strip },
        .status_bar = .{ .x = 0, .y = @max(0, height - status), .width = width, .height = @min(status, height) },
    };
}

/// Whether a window point lies in any band, in the pointer's coordinates.
/// Example: `if (bands.contains(event.x, event.y)) return chrome.bandPointer(event);`
pub fn contains(bands: Bands, x: f64, y: f64) bool {
    return within(bands.top_bar, x, y) or within(bands.shoulder, x, y) or within(bands.tab_strip, x, y) or within(bands.status_bar, x, y);
}

/// Example: `if (Bands.within(bounds, event.x, event.y)) return hit.action;`
pub fn within(bounds: Rect, x: f64, y: f64) bool {
    return x >= bounds.x and y >= bounds.y and x < @as(f64, bounds.x) + bounds.width and y < @as(f64, bounds.y) + bounds.height;
}
