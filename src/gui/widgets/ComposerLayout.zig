const Rect = @import("../render/Rect.zig");
const Canvas = @import("Canvas.zig");
const Layout = @This();

card: Rect,
editor: Rect,
context: Rect,
selectors: [3]Rect,
send: Rect,

/// Keeps every control reachable as the toolbar wraps into two or three rows.
/// Example: `const layout = ComposerLayout.resolve(canvas, bounds);`
pub fn resolve(canvas: *const Canvas, bounds: Rect) Layout {
    const px = canvas.chrome;
    const compact = bounds.width < px.px(520);
    const stacked = bounds.width < px.px(270);
    const inset = @min(px.px(20), bounds.width / 10);
    const context_height = @min(px.px(36), bounds.height / 6);
    const card_height = @max(0, bounds.height - context_height);
    const row = @min(px.px(36), card_height / (if (stacked) @as(f32, 5) else if (compact) @as(f32, 4) else 3));
    const gap = @min(px.px(8), row / 4);
    const toolbar_height = row * (if (stacked) @as(f32, 3) else if (compact) @as(f32, 2) else 1);
    const y = bounds.y + card_height - inset - toolbar_height;
    const available = @max(0, bounds.width - 2 * inset);
    const send: Rect = .{ .x = bounds.x + bounds.width - inset - row, .y = bounds.y + card_height - inset - row, .width = row, .height = row };
    var selectors: [3]Rect = undefined;
    if (stacked) {
        for (&selectors, 0..) |*slot, index| {
            slot.* = .{ .x = bounds.x + inset, .y = y + @as(f32, @floatFromInt(index)) * row, .width = @max(0, available - if (index == 2) row + gap else 0), .height = row };
        }
    } else if (compact) {
        selectors[0] = .{ .x = bounds.x + inset, .y = y, .width = available, .height = row };
        const remaining = @max(0, available - row - 2 * gap);
        selectors[1] = .{ .x = bounds.x + inset, .y = y + row, .width = remaining * 0.43, .height = row };
        selectors[2] = .{ .x = selectors[1].x + selectors[1].width + gap, .y = y + row, .width = remaining * 0.57, .height = row };
    } else {
        const remaining = @max(0, available - row - 3 * gap);
        const model = @min(px.px(240), remaining * 0.47);
        const effort = @min(px.px(122), remaining * 0.23);
        selectors[0] = .{ .x = bounds.x + inset, .y = y, .width = model, .height = row };
        selectors[1] = .{ .x = selectors[0].x + model + gap, .y = y, .width = effort, .height = row };
        selectors[2] = .{ .x = selectors[1].x + effort + gap, .y = y, .width = @min(px.px(150), remaining - model - effort), .height = row };
    }

    return .{
        .card = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = card_height },
        .editor = .{ .x = bounds.x + inset + px.px(2), .y = bounds.y + inset, .width = @max(0, available - px.px(4)), .height = @max(0, y - bounds.y - inset - gap) },
        .context = .{ .x = bounds.x + inset, .y = bounds.y + card_height - px.px(16), .width = available, .height = context_height + px.px(16) },
        .selectors = selectors,
        .send = send,
    };
}

test "composer controls fit normal narrow and tiny bounds without overlapping the editor" {
    const std = @import("std");
    var canvas: Canvas = undefined;
    canvas.chrome = .{};
    for ([_]f32{ 880, 440, 210, 110 }) |width| {
        const layout = resolve(&canvas, .{ .x = 10, .y = 20, .width = width, .height = 240 });
        for (layout.selectors) |slot| {
            try std.testing.expect(slot.x >= layout.card.x);
            try std.testing.expect(slot.x + slot.width <= layout.card.x + layout.card.width);
            try std.testing.expect(slot.y >= layout.editor.y + layout.editor.height);
            try std.testing.expect(slot.y + slot.height <= layout.card.y + layout.card.height);
        }

        try std.testing.expect(layout.send.x + layout.send.width <= layout.card.x + layout.card.width);
    }
}
