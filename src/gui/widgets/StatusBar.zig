//! Configured widgets occupy the bottom band. Prefix and copy mode replace
//! them with key hints, while the reserved TLS badge remains visible.
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const ModeBar = @import("ModeBar.zig");
const Canvas = @import("Canvas.zig");
const Layout = @import("../layout/Layout.zig");
const SlotPainter = @import("SlotPainter.zig");
const SlotRow = @import("SlotRow.zig");
const LentRow = @import("LentRow.zig");
const StatusBar = @This();

context: *const Context,
area: Rect,

/// Example: `try status.draw(canvas);`
pub fn draw(bar: StatusBar, canvas: *Canvas) !void {
    if (bar.area.width <= 0 or bar.area.height <= 0) {
        return;
    }

    try canvas.panelAt(bar.area);
    const margin = canvas.chrome.px(8);
    var row = (Layout{ .area = bar.area, .padding = .{ .left = margin, .right = margin } }).content();
    try bar.tls(canvas, &row);
    if (bar.context.projection.status_mode != .normal) {
        const mode_bar: ModeBar = .{ .mode = bar.context.projection.status_mode, .area = row };
        try mode_bar.draw(canvas);
        return;
    }

    try bar.widgets(canvas, row);
}

fn tls(bar: StatusBar, canvas: *Canvas, row: *Rect) !void {
    const projection = bar.context.projection;
    if (!projection.proxy_tls_active and !projection.proxy_system_trusted) {
        return;
    }

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

fn widgets(bar: StatusBar, canvas: *Canvas, bounds: Rect) !void {
    const quads = canvas.quads;
    const first = quads.items().len;
    defer quads.clipFrom(first, bounds);
    const layout = &bar.context.projection.bar_state.layout;
    const metrics = bar.context.projection.system_metrics;
    var bottom_width: f32 = 0;
    for (&layout.bottom) |*slot| {
        const painter: SlotPainter = .{ .slot = slot, .metrics = metrics };
        bottom_width += painter.pixelWidth(canvas);
    }

    // Existing top-right widgets follow the bottom slots without replacing
    // any of them. When both are populated, each group keeps readable space.
    const limit = if (bottom_width > 0) bounds.width / 2 else bounds.width;
    var right: SlotPainter = .{ .slot = &layout.top_right, .metrics = metrics };
    const legacy_width = @min(right.pixelWidth(canvas), limit);
    var row = bounds;
    row.width -= legacy_width;
    var lent: LentRow = undefined;
    const right_bounds: Rect = .{ .x = row.x + row.width, .y = row.y, .width = legacy_width, .height = row.height };
    if (lent.open(canvas, right_bounds)) {
        right.area = lent.area;
        const first_right = quads.items().len;
        try right.draw(&lent.canvas);
        quads.clipFrom(first_right, right_bounds);
    }

    if (legacy_width > 0 and bottom_width > 0) {
        row.width = @max(0, row.width - canvas.chrome.px(8));
    }

    const slots: SlotRow = .{ .slots = &layout.bottom, .area = row, .metrics = metrics };
    try slots.draw(canvas);
}
