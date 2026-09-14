//! The sidebar as a band of device pixels left of the cell grid, resolved
//! once per measurement like the chrome bands above and below it. It holds
//! the band width, the gap between the band and the first cell column and
//! the physical bounds an interactive resize may move between, so the grid,
//! the painter and the pointer all read the same numbers.
const std = @import("std");
const client = @import("telar-client");
const Rect = @import("../render/Rect.zig");
const SidebarRequest = @import("SidebarRequest.zig");
const SidebarFit = @import("SidebarFit.zig");
const SidebarBand = @This();

/// Logical pixels between the band's edge line and the first cell column.
pub const logical_gap: f32 = 8;
/// Logical width of the pointer strip centred on the edge line.
pub const logical_handle: f32 = 6;
/// Logical pixels one keyboard resize step moves the band.
pub const logical_step: f32 = 16;
/// Columns the workbench keeps whatever the band asks for.
pub const min_workbench_columns: u32 = 20;

/// Band width in device pixels; zero while hidden or when the window cannot
/// hold the narrowest band beside the minimum workbench.
width: u32 = 0,
/// Device pixels between the band and the grid; zero while hidden.
gap: u32 = 0,
/// Physical bounds of an interactive resize in this window.
min: u32 = @intFromFloat(client.GuiSidebar.min_width),
max: u32 = @intFromFloat(client.GuiSidebar.max_width),
scale: f32 = 1,

/// Resolves the band for one window. The width is the request scaled and
/// rounded, clamped to the configured bounds and to the room that leaves the
/// workbench its minimum columns after the gap and the right padding.
/// Example: `const band = SidebarBand.resolve(request, .{ .width = 1440, .cell_width = 9, .scale = 2 });`
pub fn resolve(request: SidebarRequest, fit: SidebarFit) SidebarBand {
    const scale = if (std.math.isFinite(fit.scale) and fit.scale > 0) fit.scale else 1;
    const gap = physical(logical_gap, scale);
    const min = physical(client.GuiSidebar.min_width, scale);
    const room = fit.width -| fit.padding_x -| gap -| min_workbench_columns * fit.cell_width;
    var band: SidebarBand = .{ .min = min, .max = @max(min, @min(physical(client.GuiSidebar.max_width, scale), room)), .scale = scale };
    if (!request.visible or room < min) {
        return band;
    }

    band.width = std.math.clamp(physical(request.logical_width, scale), band.min, band.max);
    band.gap = gap;
    return band;
}

/// Device pixels the grid starts after: the band and its gap.
/// Example: `const left = band.reserved();`
pub fn reserved(band: SidebarBand) u32 {
    return band.width + band.gap;
}

/// Example: `if (band.visible()) try sidebar.paint(&context, bands.sidebar);`
pub fn visible(band: SidebarBand) bool {
    return band.width != 0;
}

/// Clamps a requested physical width to this window's bounds.
/// Example: `const width = band.clamp(@intFromFloat(pointer_x + 1));`
pub fn clamp(band: SidebarBand, requested: u32) u32 {
    return std.math.clamp(requested, band.min, band.max);
}

/// Clamps a logical width through this window's physical bounds and returns
/// it in logical pixels again, so a preference keeps its meaning across
/// display scales.
/// Example: `preference.logical = band.clampLogical(preference.logical + 16);`
pub fn clampLogical(band: SidebarBand, logical: f32) f32 {
    return @as(f32, @floatFromInt(band.clamp(physical(logical, band.scale)))) / band.scale;
}

/// The pointer strip over the edge line, `logical_handle` wide and centred
/// on the band's last pixel column.
/// Example: `try context.bands.add(.{ .area = band.handle(area), .action = .resize_sidebar });`
pub fn handle(band: SidebarBand, area: Rect) Rect {
    const strip = @max(1, @round(logical_handle * band.scale));
    return .{ .x = area.x + area.width - 1 - @floor(strip / 2), .y = area.y, .width = strip, .height = area.height };
}

fn physical(logical: f32, scale: f32) u32 {
    const value = @round(logical * scale);
    if (!(value >= 0) or value > 65535) {
        return 0;
    }

    return @intFromFloat(value);
}

test "the band scales the preference and clamps it to the bounds and the workbench" {
    const wide: SidebarFit = .{ .width = 2000, .cell_width = 10 };
    try std.testing.expectEqual(@as(u32, 284), resolve(.{ .visible = true }, wide).width);
    try std.testing.expectEqual(@as(u32, 8), resolve(.{ .visible = true }, wide).gap);
    try std.testing.expectEqual(@as(u32, 292), resolve(.{ .visible = true }, wide).reserved());
    try std.testing.expectEqual(@as(u32, 568), resolve(.{ .visible = true }, .{ .width = 4000, .cell_width = 20, .scale = 2 }).width);
    try std.testing.expectEqual(@as(u32, 16), resolve(.{ .visible = true }, .{ .width = 4000, .cell_width = 20, .scale = 2 }).gap);
    try std.testing.expectEqual(@as(u32, 220), resolve(.{ .visible = true, .logical_width = 100 }, wide).width);
    try std.testing.expectEqual(@as(u32, 480), resolve(.{ .visible = true, .logical_width = 900 }, wide).width);
    try std.testing.expectEqual(@as(u32, 0), resolve(.{ .visible = false }, wide).width);
    try std.testing.expectEqual(@as(u32, 0), resolve(.{ .visible = false }, wide).reserved());
    // 600 px wide: 600 - 8 - 200 = 392 px remain for the band.
    const narrow = resolve(.{ .visible = true, .logical_width = 480 }, .{ .width = 600, .cell_width = 10 });
    try std.testing.expectEqual(@as(u32, 392), narrow.width);
    try std.testing.expectEqual(@as(u32, 392), narrow.max);
    // The right padding is grid inset too, so it comes off the room.
    try std.testing.expectEqual(@as(u32, 380), resolve(.{ .visible = true, .logical_width = 480 }, .{ .width = 600, .cell_width = 10, .padding_x = 12 }).width);
    // Below 220 + 8 + 200 the band gives the window back to the workbench.
    const hidden = resolve(.{ .visible = true }, .{ .width = 427, .cell_width = 10 });
    try std.testing.expectEqual(@as(u32, 0), hidden.width);
    try std.testing.expectEqual(@as(u32, 220), hidden.min);
    try std.testing.expectEqual(@as(u32, 220), resolve(.{ .visible = true }, .{ .width = 428, .cell_width = 10 }).width);
    try std.testing.expectEqual(@as(f32, 300), resolve(.{ .visible = true }, wide).clampLogical(300));
    try std.testing.expectEqual(@as(f32, 480), resolve(.{ .visible = true }, wide).clampLogical(500));
    const retina = resolve(.{ .visible = true }, .{ .width = 4000, .cell_width = 20, .scale = 2 });
    try std.testing.expectEqual(@as(f32, 300.5), retina.clampLogical(300.5));
    const grip = retina.handle(.{ .x = 0, .y = 70, .width = 568, .height = 900 });
    try std.testing.expectEqual(@as(f32, 561), grip.x);
    try std.testing.expectEqual(@as(f32, 12), grip.width);
}
