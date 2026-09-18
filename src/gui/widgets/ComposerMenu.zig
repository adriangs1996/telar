const std = @import("std");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const Target = @import("interaction/Target.zig");
const Menu = @This();

thread: @import("telar-client").ThreadView,
pane_bounds: Rect,

/// Popovers borrow catalog labels for this frame; targets own only revisions and indices.
/// Example: `try menu.draw(canvas);`
pub fn draw(menu: Menu, canvas: *Canvas) !void {
    const state = canvas.widgets orelse return;
    const open = state.composer_menu;
    const selector = open.selector orelse return;
    if (selector.pane_id != menu.thread.pane_id or open.attachment_generation != menu.thread.attachment_generation or selector.catalog_revision != menu.thread.catalog_revision or selector.options_revision != menu.thread.options_revision) {
        return;
    }

    const options: @import("ComposerOptions.zig") = .{ .thread = menu.thread, .kind = selector.kind };
    const count = options.count();
    if (count == 0) {
        return;
    }

    const padding = @min(canvas.chrome.px(8), menu.pane_bounds.width / 10);
    const rows = @min(count, @import("interaction/ComposerMenuState.zig").visible_rows);
    const row_height = @min(canvas.chrome.px(if (selector.kind == .access or selector.kind == .recent) @as(f32, 54) else 36), @max(0, menu.pane_bounds.height - 2 * padding - canvas.chrome.px(36)) / @as(f32, @floatFromInt(rows)));
    const width = @min(canvas.chrome.px(if (selector.kind == .access or selector.kind == .recent) @as(f32, 370) else 300), @max(0, menu.pane_bounds.width - 2 * padding));
    const height = row_height * @as(f32, @floatFromInt(rows)) + canvas.chrome.px(36);
    const bounds: Rect = .{ .x = std.math.clamp(open.anchor.x, menu.pane_bounds.x + padding, menu.pane_bounds.x + menu.pane_bounds.width - padding - width), .y = std.math.clamp(open.anchor.y - height - padding, menu.pane_bounds.y + padding, @max(menu.pane_bounds.y + padding, menu.pane_bounds.y + menu.pane_bounds.height - height - padding)), .width = width, .height = height };
    const first_quad = canvas.quads.items().len;
    defer canvas.quads.clipFrom(first_quad, menu.pane_bounds);
    try (@import("ComposerSurface.zig"){ .bounds = bounds, .radius = canvas.chrome.px(13) }).draw(canvas);
    _ = try state.dispatcher.add((Target{ .namespace = 0x434d, .id = .{ .generation = open.generation }, .bounds = bounds, .action = .{ .custom = 0x434d }, .focusable = false }).labelled("Composer options"));
    const palette = canvas.theme.palette;
    const title = switch (selector.kind) {
        .recent => if (menu.thread.transcript.?.recent.has_more) "16 most recent conversations" else "Recent conversations",
        .model => "Model",
        .effort => "Reasoning effort",
        .access => "Permissions",
    };
    _ = try canvas.textAt(.{ .x = bounds.x + canvas.chrome.px(14), .y = bounds.y, .width = @max(0, bounds.width - canvas.chrome.px(28)), .height = canvas.chrome.px(32) }, .{ .text = title, .face = .sans, .size = .small, .bold = true, .color = palette.subtext0 });
    const selected = options.selected();
    for (0..rows) |visible| {
        const index = open.first + @as(u8, @intCast(visible));
        if (index >= count) {
            break;
        }

        const row: Rect = .{ .x = bounds.x + canvas.chrome.px(5), .y = bounds.y + canvas.chrome.px(31) + @as(f32, @floatFromInt(visible)) * row_height, .width = @max(0, width - canvas.chrome.px(10)), .height = row_height };
        if (open.selected == index) {
            try canvas.fillRoundedAt(row, .{ .color = palette.surface1, .radius = canvas.chrome.px(7) });
        }

        const detail = options.detail(index);
        const text: Rect = .{ .x = row.x + canvas.chrome.px(10), .y = row.y, .width = @max(0, row.width - canvas.chrome.px(40)), .height = if (detail.len > 0) row.height * 0.55 else row.height };
        var storage: [@import("TextFit.zig").max_bytes]u8 = undefined;
        const label = try (@import("TextFit.zig"){ .canvas = canvas, .width = text.width }).fit(.{ .text = options.label(index), .face = .sans, .size = .body }, &storage);
        _ = try canvas.textAt(text, .{ .text = label, .face = .sans, .size = .body, .color = palette.text });
        if (detail.len > 0) {
            const fitted = try (@import("TextFit.zig"){ .canvas = canvas, .width = @max(0, row.width - canvas.chrome.px(20)) }).fit(.{ .text = detail, .face = .sans, .size = .small }, &storage);
            _ = try canvas.textAt(.{ .x = text.x, .y = text.y + text.height, .width = @max(0, row.width - canvas.chrome.px(20)), .height = row.height - text.height }, .{ .text = fitted, .face = .sans, .size = .small, .color = palette.subtext0 });
        }

        if (index == selected and selector.kind != .recent) {
            try canvas.iconAt(.{ .x = row.x + row.width - canvas.chrome.px(28), .y = row.y, .width = canvas.chrome.px(20), .height = text.height }, .{ .text = "\u{f00c}", .color = palette.accent, .size = .small });
        }

        _ = try state.dispatcher.add((Target{ .id = .{ .generation = menu.thread.attachment_generation }, .bounds = row, .action = .{ .composer_choice = .{ .selector = selector, .index = index, .menu_generation = open.generation } }, .traverse_tab = false }).labelled(options.label(index)));
    }
}
