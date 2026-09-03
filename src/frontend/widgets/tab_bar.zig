//! Ordered tab navigation.

const std = @import("std");
const core = @import("telar-core");
const workspace = @import("../workspace/root.zig");
const multiplexer = workspace.multiplexer;
const tabs_mod = workspace.tabs;
const widget = @import("context.zig");
const ui = @import("../ui/root.zig");
const bars = @import("../bars/root.zig");

const schema = core.schema;

/// One empty cell keeps neighbouring tabs from reading as a single label.
const tab_gap: u16 = 1;
/// The fullscreen marker is one icon cell plus the trailing padding cell.
const fullscreen_marker_width: u16 = 2;

pub const Input = struct {
    area: ui.Rect,
    tabs: ?*const tabs_mod.Model,
    model: *const multiplexer.Model,
    alignment: bars.Alignment = .right,
};

/// The text a tab shows: its display number, its name and, while one of its
/// panes is fullscreen, a marker drawn after the name.
const Label = struct {
    buffer: [schema.max_tab_label_bytes + 16]u8 = undefined,
    len: usize = 0,
    fullscreen: bool,

    fn init(tab: *const tabs_mod.Tab, index: usize) Label {
        var label: Label = .{ .fullscreen = tab.model.layout.isFullscreen() };
        const written = std.fmt.bufPrint(&label.buffer, " {d}:{s} ", .{
            index + 1,
            tab.labelSlice(),
        }) catch fallback: {
            const placeholder = " tab ";
            @memcpy(label.buffer[0..placeholder.len], placeholder);
            break :fallback label.buffer[0..placeholder.len];
        };
        label.len = written.len;
        return label;
    }

    fn text(label: *const Label) []const u8 {
        return label.buffer[0..label.len];
    }

    fn width(label: *const Label) u16 {
        const marker: u16 = if (label.fullscreen) fullscreen_marker_width else 0;
        return ui.measure(label.text()) + marker;
    }

    /// Draws the text, then the marker when the whole marker fits.
    fn draw(label: *const Label, context: *widget.Context, placement: Placement) void {
        const rect = placement.rect;
        const text_width = @min(ui.measure(label.text()), rect.w);
        _ = context.buffer.writeTruncated(rect, rect.x, rect.y, label.text(), text_width, placement.style);
        if (!label.fullscreen or rect.w < text_width + fullscreen_marker_width) {
            return;
        }

        const marker_x = rect.x + text_width;
        _ = context.drawIcon(rect, marker_x, rect.y, .pane_fullscreen, placement.style);
        _ = context.buffer.writeTruncated(rect, marker_x + 1, rect.y, " ", 1, placement.style);
    }
};

const Placement = struct {
    rect: ui.Rect,
    style: ui.Style,
};

pub fn render(context: *widget.Context, input: Input) void {
    if (input.tabs) |collection| {
        renderCollection(context, input, collection);
    } else if (input.model.location) |location| {
        var tab_buffer: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&tab_buffer, " tab {d} ", .{
            schema.id.raw(location.tab_id),
        }) catch " tab ";
        const width = @min(ui.measure(label), input.area.w);
        const x = alignedStart(input, width);
        const rect: ui.Rect = .{ .x = x, .y = input.area.y, .w = width, .h = 1 };
        _ = context.buffer.writeTruncated(rect, x, input.area.y, label, width, activeStyle(context));
    }
}

pub fn desiredWidth(input: Input) u16 {
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

pub fn barStyle(context: *const widget.Context) ui.Style {
    return .{ .fg = context.palette.subtext0, .bg = context.palette.panel_bg };
}

fn activeStyle(context: *const widget.Context) ui.Style {
    return .{
        .fg = context.palette.surface_dim,
        .bg = context.palette.accent,
        .flags = .{ .bold = true },
    };
}

/// Inactive tabs sit one surface above the bar so they read as buttons; the
/// gap between them keeps the bar's own background.
fn inactiveStyle(context: *const widget.Context) ui.Style {
    return .{ .fg = context.palette.subtext0, .bg = context.palette.surface0 };
}

fn hoveredStyle(context: *const widget.Context) ui.Style {
    return .{
        .fg = context.palette.text,
        .bg = context.palette.surface1,
        .flags = .{ .underline = .single },
    };
}

fn renderCollection(context: *widget.Context, input: Input, collection: *const tabs_mod.Model) void {
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

            const gap: ui.Rect = .{ .x = x, .y = input.area.y, .w = tab_gap, .h = 1 };
            _ = context.buffer.writeTruncated(gap, x, input.area.y, " ", tab_gap, barStyle(context));
            x += tab_gap;
        }

        const remaining = end -| x;
        if (remaining == 0) {
            break;
        }

        const label = Label.init(tab, index);
        const width = @min(label.width(), remaining);
        const rect: ui.Rect = .{ .x = x, .y = input.area.y, .w = width, .h = 1 };
        const action: widget.Action = .{ .select_tab = tab.location.tab_id };
        context.hits.add(rect, action);
        const style: ui.Style = if (index == collection.active_index)
            activeStyle(context)
        else if (context.isHovered(action))
            hoveredStyle(context)
        else
            inactiveStyle(context);
        label.draw(context, .{ .rect = rect, .style = style });
        x += width;
    }
}

/// The active tab is always visible; earlier tabs are added while they fit.
fn firstVisibleIndex(collection: *const tabs_mod.Model, available: u16) usize {
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
fn visibleWidth(collection: *const tabs_mod.Model, first_visible: usize, available: u16) u16 {
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

fn tabWidth(collection: *const tabs_mod.Model, index: usize, available: u16) u16 {
    const tab = if (collection.items[index]) |*value| value else return 0;
    return @min(Label.init(tab, index).width(), available);
}

fn alignedStart(input: Input, width: u16) u16 {
    return switch (input.alignment) {
        .left => input.area.x,
        .center => input.area.x + (input.area.w - width) / 2,
        .right => input.area.x + input.area.w - width,
    };
}
