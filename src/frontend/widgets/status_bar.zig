//! Compact client status at the right edge of the bottom bar.

const std = @import("std");
const multiplexer = @import("../multiplexer.zig");
const widget = @import("context.zig");
const ui = @import("../ui.zig");

pub fn render(
    context: *widget.Context,
    area: ui.Rect,
    model: *const multiplexer.Model,
    proxy_tls_active: bool,
) void {
    var buffer: [48]u8 = undefined;
    const status = if (proxy_tls_active and model.layout.isFullscreen())
        std.fmt.bufPrint(&buffer, "TLS PROXY  FULLSCREEN  {d} panes", .{model.pane_count}) catch "TLS PROXY"
    else if (proxy_tls_active)
        std.fmt.bufPrint(&buffer, "TLS PROXY  {d} pane{s}", .{
            model.pane_count,
            if (model.pane_count == 1) "" else "s",
        }) catch "TLS PROXY"
    else if (model.layout.isFullscreen())
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
