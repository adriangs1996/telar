//! The sidebar as a band of device pixels left of the cell grid, resolved
//! once per measurement like the chrome bands above and below it. It holds
//! the band width, the gap between the band and the first cell column and
//! the physical bounds an interactive resize may move between, so the grid,
//! the painter and the pointer all read the same numbers. A collapsed
//! sidebar keeps a narrow workspace rail rather than disappearing.
const std = @import("std");
const client = @import("telar-client");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const SidebarRequest = @import("SidebarRequest.zig");
const SidebarFit = @import("SidebarFit.zig");
const SidebarBand = @This();

/// Logical pixels between the band's edge line and the first cell column.
pub const logical_gap: f32 = 8;
/// Logical width of the pointer strip centred on the edge line.
pub const logical_handle: f32 = 6;
/// Logical pixels one keyboard resize step moves the band.
pub const logical_step: f32 = 16;
/// Logical width of the workspace rail a collapsed sidebar keeps.
pub const logical_rail: f32 = 52;
/// Columns the workbench keeps whatever the band asks for.
pub const min_workbench_columns: u32 = 20;

/// Band width in device pixels; zero only when the window cannot hold even
/// the rail beside the minimum workbench.
width: u32 = 0,
/// Device pixels between the band and the grid; zero while hidden.
gap: u32 = 0,
/// Whether the band is the collapsed workspace rail rather than the sidebar.
rail: bool = false,
/// Physical bounds of an interactive resize in this window.
min: u32 = @intFromFloat(client.GuiSidebar.min_width),
max: u32 = @intFromFloat(client.GuiSidebar.max_width),
scale: f32 = 1,

/// Resolves the band for one window. The width is the request scaled and
/// rounded, clamped to the configured bounds and to the room that leaves the
/// workbench its minimum columns after the gap and the right padding. A
/// collapsed request, or a window too narrow for the sidebar, gets the rail.
/// Example: `const band = SidebarBand.resolve(request, .{ .width = 1440, .cell_width = 9, .scale = 2 });`
pub fn resolve(request: SidebarRequest, fit: SidebarFit) SidebarBand {
    const scale = if (std.math.isFinite(fit.scale) and fit.scale > 0) fit.scale else 1;
    const gap = physical(logical_gap, scale);
    const min = physical(client.GuiSidebar.min_width, scale);
    const room = fit.width -| fit.padding_x -| gap -| min_workbench_columns * fit.cell_width;
    var band: SidebarBand = .{ .min = min, .max = @max(min, @min(physical(client.GuiSidebar.max_width, scale), room)), .scale = scale };
    if (!request.visible or room < min) {
        const rail = physical(logical_rail, scale);
        if (room >= rail) {
            band.width = rail;
            band.gap = gap;
            band.rail = true;
        }

        return band;
    }

    band.width = std.math.clamp(physical(request.logical_width, scale), band.min, band.max);
    band.gap = gap;
    return band;
}

/// Device pixels the grid starts after: the band and its gap.
/// Example: `const left = band.reserved();`
pub fn reserved(self: SidebarBand) u32 {
    return self.width + self.gap;
}

/// Whether the band takes any pixels, as the sidebar or as the rail.
/// Example: `const left = if (band.visible()) band.reserved() else padding;`
pub fn visible(self: SidebarBand) bool {
    return self.width != 0;
}

/// Whether the full sidebar, not the rail, occupies the band.
/// Example: `if (band.expanded()) try sidebar.draw(canvas);`
pub fn expanded(self: SidebarBand) bool {
    return self.width != 0 and !self.rail;
}

/// Clamps a requested physical width to this window's bounds.
/// Example: `const width = band.clamp(@intFromFloat(pointer_x + 1));`
pub fn clamp(self: SidebarBand, requested: u32) u32 {
    return std.math.clamp(requested, self.min, self.max);
}

/// Clamps a logical width through this window's physical bounds and returns
/// it in logical pixels again, so a preference keeps its meaning across
/// display scales.
/// Example: `preference.logical = band.clampLogical(preference.logical + 16);`
pub fn clampLogical(self: SidebarBand, logical: f32) f32 {
    return @as(f32, @floatFromInt(self.clamp(physical(logical, self.scale)))) / self.scale;
}

/// The pointer strip over the edge line, `logical_handle` wide and centred
/// on the band's last pixel column.
/// Example: `context.bands.add(.{ .area = band.handle(area), .action = .resize_sidebar });`
pub fn handle(self: SidebarBand, area: Rect) Rect {
    const strip = @max(1, @round(logical_handle * self.scale));
    return .{ .x = area.x + area.width - 1 - @floor(strip / 2), .y = area.y, .width = strip, .height = area.height };
}

fn physical(logical: f32, scale: f32) u32 {
    const value = @round(logical * scale);
    if (!(value >= 0) or value > 65535) {
        return 0;
    }

    return @intFromFloat(value);
}
