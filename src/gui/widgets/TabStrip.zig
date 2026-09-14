//! The right-aligned tab group inside navigation. The active tab always fits
//! and uses a neutral open-bottom shape, with attention represented by dots.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const TabSurface = @import("TabSurface.zig");
const PaneProgress = @import("PaneProgress.zig");
const attention = @import("attention.zig");
const TabEntry = @import("TabEntry.zig");
const StripFit = @import("StripFit.zig");
const Canvas = @import("Canvas.zig");
const PixelButton = @import("PixelButton.zig");
const AttentionDot = @import("AttentionDot.zig");
const TabStrip = @This();

context: *const Context,
area: Rect,

/// Example: `try strip.draw(canvas);`
pub fn draw(strip: TabStrip, canvas: *Canvas) !void {
    const area = strip.area;
    if (area.width <= 0 or area.height <= 0) {
        return;
    }

    const collection = strip.context.projection.tabs;
    const chrome = canvas.chrome;
    const gap = chrome.px(2);
    const plus_width = if (area.width >= chrome.px(96 + 28) + gap or collection.count == 0) @min(chrome.px(28), area.width) else 0;
    const plus_x = area.x + area.width - plus_width;
    const right = plus_x - (if (plus_width > 0) gap else @as(f32, 0));
    const inset_y = @min(chrome.px(7), area.height);
    const control: Rect = .{ .x = 0, .y = area.y + inset_y, .width = 0, .height = @max(0, area.height - inset_y) };
    if (collection.count != 0) {
        var widths: [core.max_tabs_per_workspace]f32 = undefined;
        for (collection.items[0..collection.count], 0..) |slot, index| {
            if (slot == null) {
                widths[index] = 0;
                continue;
            }

            widths[index] = try strip.width(canvas, index);
        }

        const available = @max(0, right - area.x);
        const first = firstVisible(collection.active_index, widths[0..collection.count], .{ .available = available, .gap = gap });
        var used: f32 = 0;
        var end = first;
        for (collection.items[first..collection.count], first..) |slot, index| {
            if (slot == null) {
                continue;
            }

            const spacing = if (used > 0) gap else @as(f32, 0);
            const remaining = @max(0, available - used - spacing);
            if (remaining == 0) {
                break;
            }

            widths[index] = @min(widths[index], remaining);
            used += spacing + widths[index];
            end = index + 1;
        }

        var x = right - used;
        for (collection.items[first..end], first..) |*slot, index| {
            const entry = if (slot.*) |*value| value else continue;
            if (index != first) {
                x += gap;
            }

            const tab_width = @min(widths[index], @max(0, right - x));
            if (tab_width <= 0) {
                break;
            }

            try strip.tab(canvas, .{ .tab = entry, .index = index, .bounds = .{ .x = x, .y = control.y, .width = tab_width, .height = control.height } });
            x += tab_width;
        }
    }

    if (plus_width > 0) {
        const button: PixelButton = .{
            .context = strip.context,
            .area = .{ .x = plus_x, .y = control.y + chrome.px(2), .width = plus_width, .height = @max(0, control.height - chrome.px(6)) },
            .intent = .create_tab,
            .text = "+",
            .radius = chrome.px(6),
            .inset = chrome.px(9),
        };
        try button.draw(canvas);
    }
}

fn tab(strip: TabStrip, canvas: *Canvas, entry: TabEntry) !void {
    const value = entry.tab;
    const index = entry.index;
    const bounds = entry.bounds;
    const context = strip.context;
    const palette = canvas.theme.palette;
    const chrome = canvas.chrome;
    const active = index == context.projection.tabs.active_index;
    const action: @import("action.zig").Action = .{ .intent = .{ .select_tab = value.location.tab_id } };
    const hovered = if (context.hovered) |current| std.meta.eql(current, action) else false;
    const surface: TabSurface = .{ .bounds = bounds, .active = active, .hovered = hovered };
    try surface.draw(canvas);

    const dot = attention.tabDot(context.projection, palette, value.location);
    var storage: [core.max_tab_label_bytes + 16]u8 = undefined;
    const dot_space = if (dot != null) chrome.px(AttentionDot.diameter + AttentionDot.gap) else 0;
    const label_inset = @min(chrome.px(inset), @max(0, bounds.width - dot_space - chrome.px(16)) / 2);
    var label = bounds;
    label.x += label_inset;
    label.width = @max(0, bounds.width - 2 * label_inset - dot_space);
    _ = try canvas.textAt(label, .{
        .text = text(&storage, value, index),
        .color = if (active) palette.text else if (hovered) palette.text else palette.subtext0,
        .bold = active,
        .face = .sans,
        .size = .body,
    });
    if (dot) |color| {
        const indicator: AttentionDot = .{ .area = bounds, .color = color };
        try indicator.draw(canvas);
    }

    try context.bands.add(.{ .area = bounds, .action = action });
    if (active and value.model.layout.count() == 1) {
        if (value.model.focusedPaneConst()) |pane| {
            const progress: PaneProgress = .{ .pane = pane, .area = bounds, .animation_frame = context.projection.sidebar_animation_frame };
            try progress.draw(canvas);
        }
    }
}

fn width(strip: TabStrip, canvas: *Canvas, index: usize) !f32 {
    const value = &strip.context.projection.tabs.items[index].?;
    var storage: [core.max_tab_label_bytes + 16]u8 = undefined;
    const chrome = canvas.chrome;
    const measured = try canvas.measure(.{ .text = text(&storage, value, index), .face = .sans, .bold = true, .size = .body });
    const dot = attention.tabDot(strip.context.projection, canvas.theme.palette, value.location);
    const dot_space: f32 = if (dot != null) chrome.px(AttentionDot.diameter + AttentionDot.gap) else 0;
    return @ceil(std.math.clamp(measured + 2 * chrome.px(inset) + dot_space, chrome.px(96), chrome.px(180)));
}

fn text(storage: []u8, value: *const client.Tab, index: usize) []const u8 {
    return std.fmt.bufPrint(storage, "{d} {s}{s}", .{ index + 1, value.labelSlice(), if (value.model.layout.isFullscreen()) " \u{26f6}" else "" }) catch unreachable;
}

/// Keeps the active tab visible: walks back from it while earlier tabs fit.
/// Example: `const first = firstVisible(tabs.active_index, widths, .{ .available = room, .gap = 2 });`
pub fn firstVisible(active_index: usize, widths: []const f32, fit: StripFit) usize {
    var first = active_index;
    var used = @min(widths[first], fit.available);
    while (first > 0) {
        const candidate = first - 1;
        const required = widths[candidate] + fit.gap;
        if (required > fit.available - used) {
            break;
        }

        first = candidate;
        used += required;
    }

    return first;
}

const inset: f32 = 12;
