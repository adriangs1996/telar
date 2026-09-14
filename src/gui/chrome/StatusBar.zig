//! The 26 px band along the bottom. In prefix or copy mode it shows the mode
//! chip and the key hints and nothing else. In normal mode it lends its row
//! to the Lua-configured bottom slots until those move to the sidebar
//! footer; the `tabs` slot paints nothing because tabs have their own strip.
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const ModeBar = @import("ModeBar.zig");
const SlotRow = @import("SlotRow.zig");
const StatusBar = @This();

context: *Context,
area: Rect,

/// Example: `try status.paint();`
pub fn paint(bar: StatusBar) !void {
    if (bar.area.width <= 0 or bar.area.height <= 0) {
        return;
    }

    const canvas = bar.context.canvas;
    try canvas.fillAt(bar.area, canvas.theme.palette.panel_bg);
    const margin = canvas.chrome.px(8);
    const row: Rect = .{ .x = bar.area.x + margin, .y = bar.area.y, .width = @max(0, bar.area.width - 2 * margin), .height = bar.area.height };
    if (bar.context.projection.status_mode != .normal) {
        const mode_bar: ModeBar = .{ .context = bar.context, .area = row };
        try mode_bar.paint();
        return;
    }

    const row_slots: SlotRow = .{ .context = bar.context, .slots = &bar.context.projection.bar_state.layout.bottom };
    try row_slots.paintIn(row);
}
