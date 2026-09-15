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
    if (canvas.widgets) |widgets| {
        widgets.tab_motions.begin(collection.workspace);
    }
    defer if (canvas.widgets) |widgets| widgets.tab_motions.finish();
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

        var order: [core.max_tabs_per_workspace]usize = undefined;
        for (first..end, 0..) |index, position| {
            order[position] = index;
        }
        if (canvas.widgets) |widgets| {
            const drag = &widgets.tab_drag;
            const preview: ?client.TabMoveIntent = if (drag.source != null and drag.destination != null)
                .{ .location = drag.source.?, .relative_to = drag.destination.?.relative_to, .direction = drag.destination.?.direction }
            else
                widgets.tab_drop_pending;
            if (preview) |move| {
                previewOrder(order[0 .. end - first], collection, move);
            }
        }

        var x = right - used;
        var lifted: ?TabEntry = null;
        for (order[0 .. end - first], 0..) |index, position| {
            const entry = if (collection.items[index]) |*value| value else continue;
            if (position != 0) {
                x += gap;
            }

            const tab_width = @min(widths[index], @max(0, right - x));
            if (tab_width <= 0) {
                break;
            }

            var bounds: Rect = .{ .x = x, .y = control.y, .width = tab_width, .height = control.height };
            var dragging = false;
            if (canvas.widgets) |widgets| {
                const drag = &widgets.tab_drag;
                dragging = drag.dragging and drag.source != null and drag.source.?.tab_id == entry.location.tab_id;
                if (dragging) {
                    if (drag.destination != null) {
                        try canvas.ringAt(bounds, .{ .color = canvas.theme.palette.surface1, .width = chrome.px(1), .radius = chrome.px(8) });
                    }

                    bounds.x = @floatCast(std.math.clamp(widgets.tab_pointer[0] - widgets.tab_grab_offset, area.x, @max(area.x, right - tab_width)));
                    bounds.y -= chrome.px(3);
                }
                if (canvas.animation) |clock| {
                    bounds = widgets.tab_motions.place(.{ .id = entry.location.tab_id, .bounds = bounds, .immediate = dragging }, clock);
                }
            }

            const painted: TabEntry = .{ .tab = entry, .index = index, .bounds = bounds };
            if (dragging) {
                lifted = painted;
            } else {
                try strip.tab(canvas, painted);
            }
            x += tab_width;
        }

        if (lifted) |entry| {
            try strip.tab(canvas, entry);
            try canvas.ringAt(entry.bounds, .{ .color = canvas.theme.palette.accent, .width = chrome.px(1), .radius = chrome.px(8) });
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
    const progress_pane = if (active and value.model.layout.count() == 1) value.model.focusedPaneConst() else null;
    const progress_width = if (progress_pane) |pane| try (PaneProgress{ .pane = pane, .area = bounds, .compact = true }).width(canvas) else 0;
    var storage: [core.max_tab_label_bytes + 16]u8 = undefined;
    const dot_space = progress_width + if (dot != null) chrome.px(AttentionDot.diameter + AttentionDot.gap) else @as(f32, 0);
    const label_inset = @min(chrome.px(inset), @max(0, bounds.width - dot_space - chrome.px(16)) / 2);
    var label = bounds;
    label.x += label_inset;
    label.width = @max(0, bounds.width - 2 * label_inset - dot_space);
    if (value.labelIcon()) |icon| {
        const side = @max(0, @min(label.height, @min(label.width, canvas.iconSize(.{ .text = "", .size = .body }))));
        try drawIcon(canvas, icon, .{ .x = label.x, .y = label.y + (label.height - side) / 2, .width = side, .height = side });
        const icon_space = @min(label.width, side + chrome.px(6));
        label.x += icon_space;
        label.width -= icon_space;
    }

    _ = try canvas.textAt(label, .{
        .text = text(&storage, value, index),
        .color = if (active) palette.text else if (hovered) palette.text else palette.subtext0,
        .bold = active,
        .face = .sans,
        .size = .body,
    });
    if (dot) |color| {
        var attention_bounds = bounds;
        attention_bounds.width = @max(0, attention_bounds.width - progress_width);
        const indicator: AttentionDot = .{ .area = attention_bounds, .color = color };
        try indicator.draw(canvas);
    }

    try context.bands.add(.{ .area = bounds, .action = action });
    if (progress_pane) |pane| {
        const progress: PaneProgress = .{ .pane = pane, .area = .{ .x = bounds.x, .y = bounds.y, .width = @max(0, bounds.width - chrome.px(4)), .height = bounds.height }, .compact = true, .motions = context.progress };
        try progress.draw(canvas);
    }
}

fn width(strip: TabStrip, canvas: *Canvas, index: usize) !f32 {
    const value = &strip.context.projection.tabs.items[index].?;
    var storage: [core.max_tab_label_bytes + 16]u8 = undefined;
    const chrome = canvas.chrome;
    const measured = try canvas.measure(.{ .text = text(&storage, value, index), .face = .sans, .bold = true, .size = .body });
    const icon_space = if (value.labelIcon() != null) canvas.iconSize(.{ .text = "", .size = .body }) + chrome.px(6) else 0;
    const dot = attention.tabDot(strip.context.projection, canvas.theme.palette, value.location);
    const dot_space: f32 = if (dot != null) chrome.px(AttentionDot.diameter + AttentionDot.gap) else 0;
    return @ceil(std.math.clamp(measured + icon_space + 2 * chrome.px(inset) + dot_space, chrome.px(96), chrome.px(180)));
}

fn drawIcon(canvas: *Canvas, icon: client.Icon, bounds: Rect) !void {
    const provider: core.AgentProvider = switch (icon) {
        .provider_claude => .claude,
        .provider_codex => .codex,
        .provider_pi => .pi,
        else => .unknown,
    };
    if (canvas.providerMark(provider)) |mark| {
        try canvas.spriteTintedAt(bounds, .{ .sprite = mark, .color = if (provider == .codex) canvas.theme.palette.text else .default });
        return;
    }

    try canvas.iconAt(bounds, .{ .text = icon.nerdGlyph(), .color = canvas.theme.palette.subtext0, .face = .sans, .size = .body });
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

fn previewOrder(order: []usize, tabs: *const client.TabsModel, move: client.TabMoveIntent) void {
    if (!std.meta.eql(tabs.workspace, @as(?core.WorkspaceLocation, move.location.workspace))) {
        return;
    }

    var source: ?usize = null;
    var anchor: ?usize = null;
    for (order, 0..) |index, position| {
        const tab_id = tabs.items[index].?.location.tab_id;
        if (tab_id == move.location.tab_id) {
            source = position;
        }
        if (tab_id == move.relative_to) {
            anchor = position;
        }
    }

    const from = source orelse return;
    const relative = anchor orelse return;
    if (from == relative) {
        return;
    }

    const destination: core.TabMoveTarget = .{ .relative_to = move.relative_to, .direction = move.direction };
    const to = destination.positionRelativeTo(from, relative);
    const moved = order[from];
    if (from < to) {
        std.mem.copyForwards(usize, order[from..to], order[from + 1 .. to + 1]);
    } else {
        std.mem.copyBackwards(usize, order[to + 1 .. from + 1], order[to..from]);
    }
    order[to] = moved;
}
