//! The 32 px strip under the top bar, over the workbench: one label per tab,
//! the active tab drawn as a rounded-top block in the workbench background
//! so it reads as connected to the panes below, an attention dot per tab
//! whose most urgent agent needs the person, and `+` to create a tab. The
//! shoulder left of the strip continues the sidebar surface.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const Bands = @import("Bands.zig");
const Rect = @import("../render/Rect.zig");
const PaneProgress = @import("PaneProgress.zig");
const attention = @import("attention.zig");
const TabEntry = @import("TabEntry.zig");
const StripFit = @import("StripFit.zig");
const TabStrip = @This();

context: *Context,
bands: Bands,

/// Example: `try strip.paint();`
pub fn paint(strip: TabStrip) !void {
    const canvas = strip.context.canvas;
    const palette = canvas.theme.palette;
    try canvas.fillAt(strip.bands.shoulder, palette.panel_bg);
    const area = strip.bands.tab_strip;
    if (area.width <= 0 or area.height <= 0) {
        return;
    }

    try canvas.fillAt(area, palette.panel_bg);
    if (strip.context.projection.status_mode != .normal) {
        return;
    }

    const collection = strip.context.projection.tabs;
    const chrome = canvas.chrome;
    const margin = chrome.px(8);
    const gap = chrome.px(2);
    const plus_width = @min(chrome.px(28), @max(0, area.width - margin));
    const plus_x = area.x + area.width - margin - plus_width;
    const control: Rect = .{ .x = 0, .y = area.y + chrome.px(4), .width = 0, .height = @max(0, area.height - chrome.px(4)) };
    if (collection.count != 0) {
        var widths: [core.max_tabs_per_workspace]f32 = undefined;
        for (collection.items[0..collection.count], 0..) |*slot, index| {
            const entry = if (slot.*) |*value| value else {
                widths[index] = 0;
                continue;
            };
            widths[index] = try strip.width(entry, index);
        }

        const available = @max(0, plus_x - gap - (area.x + margin));
        const first = firstVisible(collection.active_index, widths[0..collection.count], .{ .available = available, .gap = gap });
        var x = area.x + margin;
        for (collection.items[first..collection.count], first..) |*slot, index| {
            const entry = if (slot.*) |*value| value else continue;
            if (index != first) {
                x += gap;
            }

            const tab_width = @min(widths[index], @max(0, plus_x - gap - x));
            if (tab_width <= 0) {
                break;
            }

            try strip.tab(.{ .tab = entry, .index = index, .bounds = .{ .x = x, .y = control.y, .width = tab_width, .height = control.height } });
            x += tab_width;
        }
    }

    try strip.context.pill(.{
        .area = .{ .x = plus_x, .y = control.y + chrome.px(2), .width = plus_width, .height = @max(0, control.height - chrome.px(6)) },
        .intent = .create_tab,
        .text = "+",
        .radius = chrome.px(6),
        .inset = chrome.px(9),
    });
}

fn tab(strip: TabStrip, entry: TabEntry) !void {
    const value = entry.tab;
    const index = entry.index;
    const bounds = entry.bounds;
    const context = strip.context;
    const canvas = context.canvas;
    const palette = canvas.theme.palette;
    const chrome = canvas.chrome;
    const active = index == context.projection.tabs.active_index;
    const action: @import("action.zig").Action = .{ .intent = .{ .select_tab = value.location.tab_id } };
    const hovered = if (context.hovered) |current| std.meta.eql(current, action) else false;
    if (active) {
        // Two quads make a rounded top: the rounded head, then the plain body
        // covering its lower corners down to the workbench edge.
        const radius = @min(chrome.px(8), bounds.height / 2);
        try canvas.fillRoundedAt(.{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = radius * 2 }, .{ .radius = radius, .color = .default });
        try canvas.fillAt(.{ .x = bounds.x, .y = bounds.y + radius, .width = bounds.width, .height = @max(0, bounds.height - radius) }, .default);
    } else if (hovered) {
        try canvas.fillRoundedAt(.{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = @max(0, bounds.height - chrome.px(4)) }, .{ .radius = chrome.px(6), .color = palette.surface1 });
    }

    const dot = attention.tabDot(context.projection, palette, value.location);
    var storage: [core.max_tab_label_bytes + 16]u8 = undefined;
    var label = bounds;
    label.x += chrome.px(inset);
    label.width = @max(0, bounds.width - 2 * chrome.px(inset) - (if (dot != null) chrome.px(Context.dot_diameter + Context.dot_gap) else 0));
    _ = try canvas.textAt(label, .{
        .text = text(&storage, value, index),
        .color = if (active) palette.text else if (hovered) palette.text else palette.subtext0,
        .bold = active,
        .face = .sans,
    });
    if (dot) |color| {
        try context.dot(bounds, color);
    }

    try context.bands.add(.{ .area = bounds, .action = action });
    if (active and value.model.layout.count() == 1) {
        if (value.model.focusedPaneConst()) |pane| {
            const progress: PaneProgress = .{ .context = context, .pane = pane };
            try progress.paintPixels(bounds);
        }
    }
}

fn width(strip: TabStrip, value: *const client.Tab, index: usize) !f32 {
    var storage: [core.max_tab_label_bytes + 16]u8 = undefined;
    const canvas = strip.context.canvas;
    const chrome = canvas.chrome;
    const measured = try canvas.measure(.{ .text = text(&storage, value, index), .face = .sans, .bold = true });
    const dot = attention.tabDot(strip.context.projection, canvas.theme.palette, value.location);
    const dot_space: f32 = if (dot != null) chrome.px(Context.dot_diameter + Context.dot_gap) else 0;
    return @ceil(measured + 2 * chrome.px(inset) + dot_space);
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
