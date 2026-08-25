//! Compact client status at the right edge of the bottom bar.

const std = @import("std");
const multiplexer = @import("../multiplexer.zig");
const widget = @import("context.zig");
const ui = @import("../ui.zig");

pub fn render(
    context: *widget.Context,
    area: ui.Rect,
    model: *const multiplexer.Model,
) void {
    var buffer: [48]u8 = undefined;
    const status = if (model.layout.isFullscreen())
        std.fmt.bufPrint(&buffer, "FULLSCREEN  {d} panes  local", .{model.pane_count}) catch "FULLSCREEN"
    else
        std.fmt.bufPrint(&buffer, "{d} pane{s}  local", .{
            model.pane_count,
            if (model.pane_count == 1) "" else "s",
        }) catch "local";
    _ = context.buffer.writeRight(area, area.y, status, .{
        .fg = context.palette.subtext0,
        .bg = context.palette.panel_bg,
    });
}
