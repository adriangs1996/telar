//! The 26 px band along the bottom. In prefix or copy mode it shows the mode
//! chip and the key hints; in normal mode it is empty. The Lua `bottom`
//! slots belong to the TUI: the GUI surfaces are `top_right` and the sidebar
//! footer, and tabs have their own strip.
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const ModeBar = @import("ModeBar.zig");
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
    if (bar.context.projection.status_mode == .normal) {
        return;
    }

    const mode_bar: ModeBar = .{ .context = bar.context, .area = row };
    try mode_bar.paint();
}
