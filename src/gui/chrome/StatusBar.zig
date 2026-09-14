//! The 26 px band along the bottom. In prefix or copy mode it shows the mode
//! chip and the key hints and nothing else. In normal mode it lends its row
//! to the Lua-configured bottom slots until those move to the sidebar
//! footer; the `tabs` slot paints nothing because tabs have their own strip.
const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const ModeBar = @import("ModeBar.zig");
const SlotRow = @import("SlotRow.zig");
const bar_regions = @import("bar_regions.zig");
const StatusBar = @This();

context: *Context,
area: Rect,

/// Example: `try status.paint();`
pub fn paint(bar: StatusBar) !void {
    if (bar.area.width <= 0 or bar.area.height <= 0) {
        return;
    }

    const canvas = bar.context.canvas;
    try canvas.fillPixels(bar.area, canvas.theme.palette.panel_bg);
    const margin = canvas.chrome.px(8);
    const row: Rect = .{ .x = bar.area.x + margin, .y = bar.area.y, .width = @max(0, bar.area.width - 2 * margin), .height = bar.area.height };
    if (bar.context.projection.status_mode != .normal) {
        const mode_bar: ModeBar = .{ .context = bar.context, .area = row };
        try mode_bar.paint();
        return;
    }

    const slots = &bar.context.projection.bar_state.layout.bottom;
    const slot_row: SlotRow = .{ .context = bar.context };
    const cell_width: f32 = @floatFromInt(canvas.metrics.cell_width);
    var desired: [3]u16 = @splat(0);
    for (slots, 0..) |*slot, index| {
        desired[index] = @intFromFloat(@min(65535, slot_row.width(slot) / cell_width));
    }

    const columns: u16 = @intFromFloat(@min(65535, @floor(row.width / cell_width)));
    const regions = bar_regions.calculate(.{ .w = columns, .h = 1 }, desired, 2);
    for (slots, regions) |*slot, region| {
        try slot_row.paint(.{ .x = row.x + @as(f32, @floatFromInt(region.x)) * cell_width, .y = row.y, .width = @as(f32, @floatFromInt(region.w)) * cell_width, .height = row.height }, slot);
    }
}
