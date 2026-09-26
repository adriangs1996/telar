//! The floating destination of a hovered link: a rounded card above the
//! hovered row, or below it when the pane has no room above, kept inside the
//! pane's content so it never runs under the window chrome. The URI is set in
//! the terminal face and wraps to at most twelve rows. The card takes no
//! input; `PointerHover` keeps the cells it covers so a click cannot fall
//! through to text hidden under a card that is still on screen.
const cellgrid = @import("cellgrid");
const std = @import("std");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Canvas = @import("Canvas.zig");
const ChromeMetrics = @import("ChromeMetrics.zig");
const TerminalMetrics = @import("../TerminalMetrics.zig");
const WrappedLines = @import("overlays/WrappedLines.zig");
const Hit = @import("../input/LinkHit.zig");
const LinkTooltip = @This();

hit: *const Hit,

/// Logical width the card never exceeds.
pub const max_width: f32 = 640;
pub const max_rows: u32 = 12;
/// Logical pixels between the card and the pane edges or the hovered row.
const margin: f32 = 8;
/// Logical pixels between the card edge and its text.
const inset: f32 = 10;
const radius: f32 = 7;
const ring_alpha: f32 = 0.7;

/// The card's device-pixel bounds for one hovered link, or null when the pane
/// cannot hold a card. Preparation and painting call this with the same frame
/// values, so the covered cells and the painted card agree.
/// Example: `const area = LinkTooltip.place(&hit, renderer.metrics, renderer.origin, renderer.chrome) orelse return null;`
pub fn place(hit: *const Hit, metrics: TerminalMetrics, origin: [2]u32, chrome: ChromeMetrics) ?Rect {
    const bounds = metrics.rect(origin, hit.content);
    const anchor = metrics.rect(origin, hit.area);
    const cell: f32 = @floatFromInt(@max(1, metrics.cell_width));
    const row: f32 = @floatFromInt(@max(1, metrics.cell_height));
    const gap = chrome.px(margin);
    const pad = chrome.px(inset);
    const available = @min(chrome.px(max_width), bounds.width - 2 * gap);
    if (available < 2 * pad + cell) {
        return null;
    }

    const room = @floor((bounds.height - 2 * gap - 2 * pad) / row);
    if (room < 1) {
        return null;
    }

    const text = hit.match.target.uri();
    const columns: u16 = @intFromFloat(@min(65535, @floor((available - 2 * pad) / cell)));
    const lines: WrappedLines = .{ .text = text, .width = columns };
    const count = lines.count();
    const rows: u32 = @min(count, @min(max_rows, @as(u32, @intFromFloat(room))));
    const width = if (count > 1) available else @min(available, 2 * pad + @as(f32, @floatFromInt(cellgrid.text.measure(text))) * cell);
    const height = 2 * pad + @as(f32, @floatFromInt(rows)) * row;
    const above = anchor.y - gap - height;
    var y = if (above >= bounds.y) above else anchor.y + anchor.height + gap;
    y = @max(bounds.y, @min(y, bounds.y + bounds.height - height));
    const left = bounds.x + gap;
    const x = std.math.clamp(anchor.x, left, @max(left, bounds.x + bounds.width - gap - width));
    return .{ .x = x, .y = y, .width = width, .height = height };
}

/// The host cells under a placed card, so delivered hit testing can swallow them.
/// Example: `const cells = LinkTooltip.cover(area, renderer.metrics, renderer.origin);`
pub fn cover(area: Rect, metrics: TerminalMetrics, origin: [2]u32) cellgrid.Rect {
    const cell: f32 = @floatFromInt(@max(1, metrics.cell_width));
    const row: f32 = @floatFromInt(@max(1, metrics.cell_height));
    const left = @max(0, area.x - @as(f32, @floatFromInt(origin[0])));
    const top = @max(0, area.y - @as(f32, @floatFromInt(origin[1])));
    const x: u16 = @intFromFloat(@min(65535, @floor(left / cell)));
    const y: u16 = @intFromFloat(@min(65535, @floor(top / row)));
    const right: u16 = @intFromFloat(@min(65535, @ceil((left + area.width) / cell)));
    const bottom: u16 = @intFromFloat(@min(65535, @ceil((top + area.height) / row)));
    return .{ .x = x, .y = y, .w = right -| x, .h = bottom -| y };
}

/// Paints the card the prepared frame placed for this link.
/// Example: `try (LinkTooltip{ .hit = hit }).draw(canvas);`
pub fn draw(self: LinkTooltip, canvas: *Canvas) !void {
    const area = place(self.hit, canvas.metrics, canvas.origin, canvas.chrome) orelse return;
    const palette = canvas.theme.palette;
    const chrome = canvas.chrome;
    const cell: f32 = @floatFromInt(@max(1, canvas.metrics.cell_width));
    const row: f32 = @floatFromInt(@max(1, canvas.metrics.cell_height));
    const pad = chrome.px(inset);
    const columns: u16 = @intFromFloat(@min(65535, @floor((area.width - 2 * pad) / cell)));
    const rows: u32 = @intFromFloat(@max(0, @floor((area.height - 2 * pad) / row)));
    const text = self.hit.match.target.uri();
    var lines: WrappedLines = .{ .text = text, .width = columns };
    const count = lines.count();
    const first = canvas.quads.items().len;
    defer canvas.quads.clipFrom(first, area);
    try canvas.fillRoundedAt(area, .{ .color = palette.surface0, .radius = chrome.px(radius) });
    try canvas.ringAt(area, .{ .color = palette.overlay0, .width = 1, .radius = chrome.px(radius), .alpha = ring_alpha });
    var index: u32 = 0;
    while (index < rows) : (index += 1) {
        const line = lines.next() orelse break;
        const clipped = index + 1 == rows and count > rows;
        const bounds: Rect = .{ .x = area.x + pad, .y = area.y + pad + @as(f32, @floatFromInt(index)) * row, .width = area.width - 2 * pad - (if (clipped) cell else 0), .height = row };
        _ = try canvas.textAt(bounds, .{ .text = line, .color = palette.text });
        if (clipped) {
            _ = try canvas.textAt(.{ .x = area.x + area.width - pad - cell, .y = bounds.y, .width = cell, .height = row }, .{ .text = "\u{2026}", .color = palette.subtext0 });
        }
    }
}
