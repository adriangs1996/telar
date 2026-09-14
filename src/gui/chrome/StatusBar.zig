//! Configured widgets occupy the bottom band. Prefix and copy mode replace
//! them with key hints, while the reserved TLS badge remains visible.
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const ModeBar = @import("ModeBar.zig");
const Canvas = @import("Canvas.zig");
const Layout = @import("../layout/Layout.zig");
const SlotPainter = @import("SlotPainter.zig");
const SlotRow = @import("SlotRow.zig");
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
    var row = (Layout{ .area = bar.area, .padding = .{ .left = margin, .right = margin } }).content();
    try bar.tls(&row);
    if (bar.context.projection.status_mode != .normal) {
        const mode_bar: ModeBar = .{ .context = bar.context, .area = row };
        try mode_bar.paint();
        return;
    }

    try bar.widgets(row);
}

fn tls(bar: StatusBar, row: *Rect) !void {
    const projection = bar.context.projection;
    if (!projection.proxy_tls_active and !projection.proxy_system_trusted) {
        return;
    }

    const canvas = bar.context.canvas;
    const palette = canvas.theme.palette;
    const badge = " TLS ";
    const width = @min(try canvas.measure(.{ .text = badge }), row.width);
    row.width -= width;
    _ = try canvas.textAt(.{ .x = row.x + row.width, .y = row.y, .width = width, .height = row.height }, .{
        .text = badge,
        .color = if (!projection.proxy_tls_active) palette.yellow else if (projection.proxy_tls_scope == .wildcard) palette.red else palette.peach,
        .bold = true,
    });
}

fn widgets(bar: StatusBar, bounds: Rect) !void {
    const quads = bar.context.canvas.quads;
    const first = quads.items().len;
    defer quads.clipFrom(first, bounds);
    const layout = &bar.context.projection.bar_state.layout;
    const painter: SlotPainter = .{ .context = bar.context };
    var bottom_width: f32 = 0;
    for (&layout.bottom) |*slot| {
        bottom_width += painter.pixelWidth(slot);
    }

    // Existing top-right widgets follow the bottom slots without replacing
    // any of them. When both are populated, each group keeps readable space.
    const limit = if (bottom_width > 0) bounds.width / 2 else bounds.width;
    const legacy_width = @min(painter.pixelWidth(&layout.top_right), limit);
    var row = bounds;
    row.width -= legacy_width;
    try painter.paintIn(.{ .x = row.x + row.width, .y = row.y, .width = legacy_width, .height = row.height }, &layout.top_right);
    if (legacy_width > 0 and bottom_width > 0) {
        row.width = @max(0, row.width - bar.context.canvas.chrome.px(8));
    }

    const slots: SlotRow = .{ .context = bar.context, .slots = &layout.bottom };
    try slots.paintIn(row);
}
