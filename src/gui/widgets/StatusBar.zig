//! Configured components occupy the bottom band. Prefix and copy mode replace
//! them with key hints, while the reserved TLS badge remains visible.
const Context = @import("Context.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const ModeBar = @import("ModeBar.zig");
const Canvas = @import("Canvas.zig");
const Layout = gfx.Layout;
const BarRow = @import("BarRow.zig");
const inline_nodes = @import("inline_nodes.zig");
const StatusBar = @This();

const margin: f32 = 8;
const badge_padding: f32 = 6;
const badge_height: f32 = 16;
const badge_radius: f32 = 4;
const badge_alpha: f32 = 0.16;
const badge_gap: f32 = 10;

context: *const Context,
area: Rect,

/// Example: `try status.draw(canvas);`
pub fn draw(self: StatusBar, canvas: *Canvas) !void {
    if (self.area.width <= 0 or self.area.height <= 0) {
        return;
    }

    try canvas.panelAt(self.area);
    const inset = canvas.chrome.px(margin);
    var row = (Layout{ .area = self.area, .padding = .{ .left = inset, .right = inset } }).content();
    try self.tls(canvas, &row);
    if (self.context.projection.status_mode != .normal) {
        const mode_bar: ModeBar = .{ .mode = self.context.projection.status_mode, .area = row };
        try mode_bar.draw(canvas);
        return;
    }

    const quads = canvas.quads;
    const first = quads.items().len;
    defer quads.clipFrom(first, row);
    try (BarRow{ .context = self.context, .area = row }).draw(canvas);
}

fn tls(self: StatusBar, canvas: *Canvas, row: *Rect) !void {
    const projection = self.context.projection;
    if (!projection.proxy_tls_active and !projection.proxy_system_trusted) {
        return;
    }

    const chrome = canvas.chrome;
    const palette = canvas.theme.palette;
    const color = if (!projection.proxy_tls_active) palette.yellow else if (projection.proxy_tls_scope == .wildcard) palette.red else palette.peach;
    var label = inline_nodes.caption("TLS");
    label.color = color;
    const width = @min(try canvas.measure(label) + 2 * chrome.px(badge_padding), row.width);
    const height = chrome.px(badge_height);
    const chip: Rect = .{
        .x = row.x + row.width - width,
        .y = @round(row.y + (row.height - height) / 2),
        .width = width,
        .height = height,
    };
    try canvas.fillRoundedAt(chip, .{ .radius = chrome.px(badge_radius), .color = color, .alpha = badge_alpha });
    _ = try canvas.textAt(.{
        .x = chip.x + chrome.px(badge_padding),
        .y = chip.y,
        .width = @max(0, width - chrome.px(badge_padding)),
        .height = chip.height,
    }, label);
    row.width = @max(0, row.width - width - chrome.px(badge_gap));
}
