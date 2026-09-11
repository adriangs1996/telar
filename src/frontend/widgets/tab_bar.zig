//! Ordered tab navigation.

const ContextType = @import("Context.zig");
const TabBarInput = @import("TabBarInput.zig");
const std = @import("std");
const raw_module = @import("telar-core").raw;
const measure_module = @import("telar-core").measure;
const RectType = @import("telar-core").Rect;
const Label = @import("Label.zig");
const StyleType = @import("telar-core").Style;
const TabsModel = @import("telar-client").TabsModel;
const widget = @import("context_support.zig");

/// One empty cell keeps neighbouring tabs from reading as a single label.
const tab_gap: u16 = 1;
/// The fullscreen marker is one icon cell plus the trailing padding cell.
pub const fullscreen_marker_width: u16 = 2;

pub fn render(context: *ContextType, input: TabBarInput) void {
    if (input.tabs) |collection| {
        renderCollection(context, input, collection);
    } else if (input.model.location) |location| {
        var tab_buffer: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&tab_buffer, " tab {d} ", .{
            raw_module(location.tab_id),
        }) catch " tab ";
        const width = @min(measure_module(label), input.area.w);
        const x = alignedStart(input, width);
        const rect: RectType = .{ .x = x, .y = input.area.y, .w = width, .h = 1 };
        _ = context.buffer.writeTruncated(rect, .{ .point = .{ .x = x, .y = input.area.y }, .text = label, .max_width = width, .style = activeStyle(context) });
    }
}

pub fn desiredWidth(input: TabBarInput) u16 {
    if (input.tabs) |collection| {
        var total: u16 = 0;
        for (collection.items[0..collection.count], 0..) |*slot, index| {
            const tab = if (slot.*) |*value| value else continue;
            if (index != 0) {
                total +|= tab_gap;
            }

            total +|= Label.init(tab, index).width();
        }

        return total;
    }
    if (input.model.location) |_| {
        return 32;
    }

    return 0;
}

pub fn barStyle(context: *const ContextType) StyleType {
    return .{ .fg = context.palette.subtext0, .bg = context.palette.panel_bg };
}

fn activeStyle(context: *const ContextType) StyleType {
    return .{
        .fg = context.palette.surface_dim,
        .bg = context.palette.accent,
        .flags = .{ .bold = true },
    };
}

/// Inactive tabs sit one surface above the bar so they read as buttons; the
/// gap between them keeps the bar's own background.
fn inactiveStyle(context: *const ContextType) StyleType {
    return .{ .fg = context.palette.subtext0, .bg = context.palette.surface0 };
}

fn hoveredStyle(context: *const ContextType) StyleType {
    return .{
        .fg = context.palette.text,
        .bg = context.palette.surface1,
        .flags = .{ .underline = .single },
    };
}

fn renderCollection(context: *ContextType, input: TabBarInput, collection: *const TabsModel) void {
    if (collection.count == 0) {
        return;
    }

    const first_visible = firstVisibleIndex(collection, input.area.w);
    const total = visibleWidth(collection, first_visible, input.area.w);
    const end = input.area.x + input.area.w;
    var x = alignedStart(input, total);
    for (collection.items[first_visible..collection.count], first_visible..) |*slot, index| {
        const tab = if (slot.*) |*value| value else continue;
        if (index != first_visible) {
            if (x >= end) {
                break;
            }

            const gap: RectType = .{ .x = x, .y = input.area.y, .w = tab_gap, .h = 1 };
            _ = context.buffer.writeTruncated(gap, .{ .point = .{ .x = x, .y = input.area.y }, .text = " ", .max_width = tab_gap, .style = barStyle(context) });
            x += tab_gap;
        }

        const remaining = end -| x;
        if (remaining == 0) {
            break;
        }

        const label = Label.init(tab, index);
        const width = @min(label.width(), remaining);
        const rect: RectType = .{ .x = x, .y = input.area.y, .w = width, .h = 1 };
        const action: widget.Action = .{ .select_tab = tab.location.tab_id };
        context.hits.add(rect, action);
        const style: StyleType = if (index == collection.active_index)
            activeStyle(context)
        else if (context.isHovered(action))
            hoveredStyle(context)
        else
            inactiveStyle(context);
        label.draw(context, .{ .rect = rect, .style = style });
        if (index == collection.active_index and input.model.layout.count() == 1) {
            decorateProgress(context, input, rect);
        }
        x += width;
    }
}

fn decorateProgress(context: *ContextType, input: TabBarInput, rect: RectType) void {
    const pane = input.model.focusedPaneConst() orelse return;
    if (pane.progress_state == .remove or rect.w == 0) {
        return;
    }

    const color = switch (pane.progress_state) {
        .@"error" => context.palette.red,
        .pause => context.palette.yellow,
        else => context.palette.teal,
    };
    const length: u16 = switch (pane.progress_state) {
        .indeterminate => 1,
        .set, .pause => @max(1, @as(u16, @intCast((@as(u32, rect.w) * (pane.progress_percent orelse 0)) / 100))),
        .@"error" => if (pane.progress_percent) |percent|
            @max(1, @as(u16, @intCast((@as(u32, rect.w) * percent) / 100)))
        else
            rect.w,
        .remove => unreachable,
    };
    const start = if (pane.progress_state == .indeterminate)
        rect.x + bouncingPosition(rect.w, input.animation_frame)
    else
        rect.x;
    var x: u16 = 0;
    while (x < length and start + x < rect.x + rect.w) : (x += 1) {
        const cell = context.buffer.at(start + x, rect.y) orelse continue;
        cell.style.bg = color;
        cell.style.fg = context.palette.surface_dim;
        cell.style.flags.bold = true;
    }
}

fn bouncingPosition(width: u16, frame: u8) u16 {
    if (width <= 1) {
        return 0;
    }

    const phase: u16 = if (frame < 128) frame else 255 - @as(u16, frame);
    return @intCast((@as(u32, width - 1) * phase) / 127);
}

/// The active tab is always visible; earlier tabs are added while they fit.
fn firstVisibleIndex(collection: *const TabsModel, available: u16) usize {
    var first_visible = collection.active_index;
    var used = tabWidth(collection, first_visible, available);
    while (first_visible > 0) {
        const candidate = first_visible - 1;
        const width = tabWidth(collection, candidate, available) +| tab_gap;
        if (width > available -| used) {
            break;
        }

        first_visible = candidate;
        used += width;
    }

    return first_visible;
}

/// The block anchors to its alignment edge: when the tabs do not fill the
/// region the unused cells stay on the other side.
fn visibleWidth(collection: *const TabsModel, first_visible: usize, available: u16) u16 {
    var total: u16 = 0;
    for (first_visible..collection.count) |index| {
        const gap: u16 = if (index != first_visible) tab_gap else 0;
        const width = tabWidth(collection, index, available) +| gap;
        total += @min(width, available -| total);
        if (total == available) {
            break;
        }
    }

    return total;
}

fn tabWidth(collection: *const TabsModel, index: usize, available: u16) u16 {
    const tab = if (collection.items[index]) |*value| value else return 0;
    return @min(Label.init(tab, index).width(), available);
}

fn alignedStart(input: TabBarInput, width: u16) u16 {
    return switch (input.alignment) {
        .left => input.area.x,
        .center => input.area.x + (input.area.w - width) / 2,
        .right => input.area.x + input.area.w - width,
    };
}
