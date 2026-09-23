//! Ordered tab navigation.

const data = @import("model");
const core = @import("telar-core");
const client = @import("telar-client");
const ContextType = @import("Context.zig");
const TabBarInput = @import("TabBarInput.zig");
const Label = @import("Label.zig");
const widget = @import("context_support.zig");

/// One empty cell keeps neighbouring tabs from reading as a single label.
const tab_gap: u16 = 1;
/// The fullscreen marker is one icon cell plus the trailing padding cell.
pub const fullscreen_marker_width: u16 = 2;

pub fn render(context: *ContextType, input: TabBarInput) void {
    const model = input.model;
    if (model.tabs.count == 0) {
        return;
    }

    const first_visible = firstVisibleIndex(model, input.area.w);
    const total = visibleWidth(model, first_visible, input.area.w);
    const end = input.area.x + input.area.w;
    var x = alignedStart(input, total);
    for (first_visible..model.tabs.count) |slot| {
        if (slot != first_visible) {
            if (x >= end) {
                break;
            }

            const gap: core.Rect = .{ .x = x, .y = input.area.y, .w = tab_gap, .h = 1 };
            _ = context.buffer.writeTruncated(gap, .{ .point = .{ .x = x, .y = input.area.y }, .text = " ", .max_width = tab_gap, .style = barStyle(context) });
            x += tab_gap;
        }

        const remaining = end -| x;
        if (remaining == 0) {
            break;
        }

        const label = Label.init(model, slot);
        const width = @min(label.width(), remaining);
        const rect: core.Rect = .{ .x = x, .y = input.area.y, .w = width, .h = 1 };
        const action: widget.Action = .{ .select_tab = model.tabs.location[slot].tab_id };
        context.hits.add(rect, action);
        const style: core.Style = if (slot == input.tab)
            activeStyle(context)
        else if (context.isHovered(action))
            hoveredStyle(context)
        else
            inactiveStyle(context);
        label.draw(context, .{ .rect = rect, .style = style });
        if (slot == input.tab and model.tabs.layout[slot].count() == 1) {
            decorateProgress(context, input, rect);
        }
        x += width;
    }
}

pub fn desiredWidth(input: TabBarInput) u16 {
    var total: u16 = 0;
    for (0..input.model.tabs.count) |slot| {
        if (slot != 0) {
            total +|= tab_gap;
        }

        total +|= Label.init(input.model, slot).width();
    }

    return total;
}

pub fn barStyle(context: *const ContextType) core.Style {
    return .{ .fg = context.palette.subtext0, .bg = context.palette.panel_bg };
}

fn activeStyle(context: *const ContextType) core.Style {
    return .{
        .fg = context.palette.surface_dim,
        .bg = context.palette.accent,
        .flags = .{ .bold = true },
    };
}

/// Inactive tabs sit one surface above the bar so they read as buttons; the
/// gap between them keeps the bar's own background.
fn inactiveStyle(context: *const ContextType) core.Style {
    return .{ .fg = context.palette.subtext0, .bg = context.palette.surface0 };
}

fn hoveredStyle(context: *const ContextType) core.Style {
    return .{
        .fg = context.palette.text,
        .bg = context.palette.surface1,
        .flags = .{ .underline = .single },
    };
}

fn decorateProgress(context: *ContextType, input: TabBarInput, rect: core.Rect) void {
    const pane = data.tab_layout.focusedPaneConst(input.model, input.tab) orelse return;
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
fn firstVisibleIndex(model: *const data.Model, available: u16) usize {
    var first_visible = model.tabs.active;
    var used = tabWidth(model, first_visible, available);
    while (first_visible > 0) {
        const candidate = first_visible - 1;
        const width = tabWidth(model, candidate, available) +| tab_gap;
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
fn visibleWidth(model: *const data.Model, first_visible: usize, available: u16) u16 {
    var total: u16 = 0;
    for (first_visible..model.tabs.count) |index| {
        const gap: u16 = if (index != first_visible) tab_gap else 0;
        const width = tabWidth(model, index, available) +| gap;
        total += @min(width, available -| total);
        if (total == available) {
            break;
        }
    }

    return total;
}

fn tabWidth(model: *const data.Model, slot: usize, available: u16) u16 {
    return @min(Label.init(model, slot).width(), available);
}

fn alignedStart(input: TabBarInput, width: u16) u16 {
    return switch (input.alignment) {
        .left => input.area.x,
        .center => input.area.x + (input.area.w - width) / 2,
        .right => input.area.x + input.area.w - width,
    };
}
