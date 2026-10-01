//! Configured components occupy the bottom band. Prefix and copy mode replace
//! them with key hints, while the reserved TLS badge and the client
//! diagnostic, the reason the last bar, panel, pick or action failed,
//! remain visible. A press on the diagnostic chip dismisses it.
const Context = @import("Context.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const ModeBar = @import("ModeBar.zig");
const Canvas = @import("Canvas.zig");
const Layout = gfx.Layout;
const BarRow = @import("BarRow.zig");
const inline_nodes = @import("inline_nodes.zig");
const Label = @import("Label.zig");
const TextFit = @import("TextFit.zig");
const StatusBar = @This();

const margin: f32 = 8;
const badge_padding: f32 = 6;
const badge_height: f32 = 16;
const badge_radius: f32 = 4;
const badge_alpha: f32 = 0.16;
const badge_gap: f32 = 10;
/// The diagnostic takes at most this share of the row; bars keep the rest.
const diagnostic_share: f32 = 0.5;

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
    try self.diagnostic(canvas, &row);
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

    const palette = canvas.theme.palette;
    const color = if (!projection.proxy_tls_active) palette.yellow else if (projection.proxy_tls_scope == .wildcard) palette.red else palette.peach;
    var label = inline_nodes.caption("TLS");
    label.color = color;
    _ = try badge(canvas, row, label);
}

/// Shows the client diagnostic until its source clears it, cut to fit.
fn diagnostic(self: StatusBar, canvas: *Canvas, row: *Rect) !void {
    const text = self.context.projection.diagnostic orelse return;
    var label = inline_nodes.caption(text);
    label.color = canvas.theme.palette.red;

    const padding = canvas.chrome.px(badge_padding);
    var buffer: [TextFit.max_bytes]u8 = undefined;
    const fit: TextFit = .{
        .canvas = canvas,
        .width = @max(0, row.width * diagnostic_share - 2 * padding),
    };
    label.text = try fit.fit(label, &buffer);
    if (label.text.len == 0) {
        return;
    }

    const chip = try badge(canvas, row, label);
    self.context.bands.add(.{
        .area = chip,
        .action = .{
            .intent = .diagnostic_dismiss,
        },
    });
}

/// Draws one chip at the row's right end, takes its width from the row and
/// returns where it went.
fn badge(canvas: *Canvas, row: *Rect, label: Label) !Rect {
    const chrome = canvas.chrome;
    const width = @min(try canvas.measure(label) + 2 * chrome.px(badge_padding), row.width);
    const height = chrome.px(badge_height);
    const chip: Rect = .{
        .x = row.x + row.width - width,
        .y = @round(row.y + (row.height - height) / 2),
        .width = width,
        .height = height,
    };
    try canvas.fillRoundedAt(
        chip,
        .{
            .radius = chrome.px(badge_radius),
            .color = label.color,
            .alpha = badge_alpha,
        },
    );
    _ = try canvas.textAt(.{
        .x = chip.x + chrome.px(badge_padding),
        .y = chip.y,
        .width = @max(0, width - chrome.px(badge_padding)),
        .height = chip.height,
    }, label);
    row.width = @max(0, row.width - width - chrome.px(badge_gap));
    return chip;
}
