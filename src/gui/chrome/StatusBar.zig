//! The 26 px band along the bottom. In prefix or copy mode it shows the mode
//! chip and the key hints; in normal mode it is empty. The Lua `bottom`
//! slots belong to the TUI: the GUI surfaces are `top_right` and the sidebar
//! footer, and tabs have their own strip.
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const ModeBar = @import("ModeBar.zig");
const Canvas = @import("Canvas.zig");
const Layout = @import("../layout/Layout.zig");
const StatusBar = @This();

context: *Context,
area: Rect,

/// Example: `try status.draw(canvas);`
pub fn draw(widget: StatusBar, canvas: *Canvas) !void {
    var context = widget.context.*;
    context.canvas = canvas;
    var bar = widget;
    bar.context = &context;
    if (bar.area.width <= 0 or bar.area.height <= 0) {
        return;
    }

    try canvas.panelAt(bar.area);
    const margin = canvas.chrome.px(8);
    const row = (Layout{ .area = bar.area, .padding = .{ .left = margin, .right = margin } }).content();
    if (bar.context.projection.status_mode == .normal) {
        return;
    }

    const mode_bar: ModeBar = .{ .context = bar.context, .area = row };
    try mode_bar.paint();
}
