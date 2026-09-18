//! An owned hover destination; no message bytes survive the synchronous borrow.
const std = @import("std");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const WrappedLines = @import("overlays/WrappedLines.zig");
const Preview = @This();

control: @import("interaction/MessageLinkControl.zig"),
anchor: Rect,
pointer: [2]f64,
destination: @import("MessageLinkDestination.zig"),

/// Draws after conversation clipping, only while the new frame retains this hit.
/// The passive tooltip never takes input away from the underlying label.
/// Example: `try preview.draw(canvas);`
pub fn draw(preview: *const Preview, canvas: *Canvas) !void {
    const state = canvas.widgets orelse return;
    const registry = state.dispatcher.maps.preparing();
    if (registry.modal_layer != 0 or state.composer_menu.selector != null) {
        return;
    }

    const target = registry.at(preview.pointer) orelse return;
    if (target.action != .message_link or !std.meta.eql(target.action.message_link, preview.control) or !std.meta.eql(target.bounds, preview.anchor)) {
        return;
    }

    const window_width: f32 = @floatFromInt(canvas.viewport[0]);
    const window_height: f32 = @floatFromInt(canvas.viewport[1]);
    const inset = canvas.chrome.px(10);
    const margin = canvas.chrome.px(8);
    const cell: f32 = @floatFromInt(@max(1, canvas.metrics.cell_width));
    const row: f32 = @floatFromInt(@max(1, canvas.metrics.cell_height));
    const available = @min(canvas.chrome.px(640), window_width - 2 * margin);
    if (available < 2 * inset + cell or window_height < 2 * margin + 2 * inset + row) {
        return;
    }

    const text = preview.destination.text();
    const columns: u16 = @intFromFloat(@min(65535, @floor((available - 2 * inset) / cell)));
    var lines: WrappedLines = .{ .text = text, .width = columns };
    const count = lines.count();
    const rows: u32 = @min(count, @as(u32, @intFromFloat(@min(12, @floor((window_height - 2 * margin - 2 * inset) / row)))));
    const width = if (count > 1) available else @min(available, 2 * inset + try canvas.measure(.{ .text = text }));
    const height = 2 * inset + @as(f32, @floatFromInt(rows)) * row;
    const above = preview.anchor.y - margin - height;
    const proposed_y = if (above >= margin) above else preview.anchor.y + preview.anchor.height + margin;
    const area: Rect = .{ .x = std.math.clamp(preview.anchor.x, margin, window_width - margin - width), .y = std.math.clamp(proposed_y, margin, window_height - margin - height), .width = width, .height = height };
    const first = canvas.quads.items().len;
    defer canvas.quads.clipFrom(first, area);
    try canvas.fillRoundedAt(area, .{ .color = canvas.theme.palette.surface0, .radius = canvas.chrome.px(7) });
    try canvas.ringAt(area, .{ .color = canvas.theme.palette.overlay0, .width = 1, .radius = canvas.chrome.px(7), .alpha = 0.7 });
    var index: u32 = 0;
    while (index < rows) : (index += 1) {
        const line = lines.next() orelse break;
        const clipped = index + 1 == rows and count > rows;
        const bounds: Rect = .{ .x = area.x + inset, .y = area.y + inset + @as(f32, @floatFromInt(index)) * row, .width = width - 2 * inset - (if (clipped) cell else 0), .height = row };
        _ = try canvas.textAt(bounds, .{ .text = line, .color = canvas.theme.palette.text });
        if (clipped) {
            _ = try canvas.textAt(.{ .x = area.x + width - inset - cell, .y = bounds.y, .width = cell, .height = row }, .{ .text = "…", .color = canvas.theme.palette.subtext0 });
        }
    }
}
