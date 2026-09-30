//! The tab group in navigation, packed from the left. Each tab is a quiet
//! pill: its application mark in a translucent chip, its caption and a
//! trailing status. Only the selected tab is filled; numbers appear in the
//! chips only while the prefix waits for a digit. The selected tab keeps its
//! whole caption while the others give up width in steps: whole caption,
//! faded caption, chip alone. Past that the tabs farthest from the selection
//! hide behind a counter that keeps their attention. While the pointer rests
//! on the strip, widths stay laid out around the tab they were built for, so
//! a click changes the selection without moving tabs under the pointer.
const cellgrid = @import("cellgrid");
const data = @import("model");
const action_module = @import("action.zig");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const PaneProgress = @import("PaneProgress.zig");
const ProgressRing = @import("ProgressRing.zig");
const attention = @import("attention.zig");
const application_mark = @import("application_mark.zig");
const StripFit = @import("StripFit.zig");
const Canvas = @import("Canvas.zig");
const ChromeMetrics = @import("ChromeMetrics.zig");
const Label = @import("Label.zig");
const PixelButton = @import("PixelButton.zig");
const TabStrip = @This();

const pill_height: f32 = 30;
const pill_radius: f32 = 10;
const lead: f32 = 5;
const trail: f32 = 12;
const spacing: f32 = 8;
const chip_side: f32 = 20;
const chip_radius: f32 = 6;
const chip_alpha: f32 = 0.06;
const chip_selected_alpha: f32 = 0.1;
const mark_side: f32 = 14;
const strip_gap: f32 = 2;
const inactive_max: f32 = 220;
const selected_max: f32 = 300;
const selected_share: f32 = 0.55;
const caption_min: f32 = 56;
const fade_width: f32 = 20;
const counter_width: f32 = 36;
const plus_side: f32 = 30;
const dot_side: f32 = 6;
const spinner_side: f32 = 12;
const spinner_fraction: f32 = 0.3;
const spinner_steps = 8;
const spinner_step_ns = 120 * std.time.ns_per_ms;
const cap_steps = 24;
const max_tabs = core.max_tabs_per_workspace;

context: *const Context,
area: Rect,

/// Example: `try strip.draw(canvas);`
pub fn draw(self: TabStrip, canvas: *Canvas) !void {
    const area = self.area;
    if (area.width <= 0 or area.height <= 0) {
        return;
    }

    if (self.context.tab_strip) |strip| {
        strip.* = area;
    }

    const model = self.context.projection.model;
    const collection = &model.tabs;
    if (canvas.widgets) |widgets| {
        widgets.tab_motions.begin(model.workspace);
    }
    defer if (canvas.widgets) |widgets| widgets.tab_motions.finish();

    const chrome = canvas.chrome;
    const height = @min(area.height, chrome.px(pill_height));
    const row: Rect = .{ .x = area.x, .y = area.y + @floor((area.height - height) / 2), .width = area.width, .height = height };
    const plus = @min(chrome.px(plus_side), row.width);
    const gap = chrome.px(strip_gap);
    var x = row.x;
    if (collection.count != 0) {
        var sizes: [max_tabs]Measure = undefined;
        for (0..collection.count) |index| {
            sizes[index] = try self.measure(canvas, index);
        }

        const room: Room = .{ .room = @max(0, row.width - plus - gap), .metrics = .of(chrome) };
        var layout = plan(sizes[0..collection.count], self.layoutFocus(), room);
        if (!layout.shows(collection.active)) {
            // A frozen layout never hides the selection: rebuild around it.
            self.anchorOn(collection.active);
            layout = plan(sizes[0..collection.count], collection.active, room);
        }

        x = try self.drawTabs(canvas, row, .{ .layout = &layout, .sizes = sizes[0..collection.count] });
    }

    if (plus > 0 and x + plus <= row.x + row.width) {
        const button: PixelButton = .{
            .context = self.context,
            .area = .{ .x = x, .y = row.y, .width = plus, .height = row.height },
            .intent = .create_tab,
            .text = "+",
            .alignment = .center,
            .background = false,
            .hover_fill = true,
            .radius = chrome.px(pill_radius),
        };
        try button.draw(canvas);
    }
}

// The tab the widths are laid out around: the selected one, unless the
// pointer rests on the strip and the anchor from before is still open.
fn layoutFocus(self: TabStrip) usize {
    const collection = &self.context.projection.model.tabs;
    const active = collection.active;
    const record = self.context.tab_anchor orelse return active;
    if (self.context.pointer_in_tabs) {
        if (record.*) |anchor| {
            if (collection.find(anchor)) |slot| {
                return slot;
            }
        }
    }

    self.anchorOn(active);
    return active;
}

fn anchorOn(self: TabStrip, slot: usize) void {
    if (self.context.tab_anchor) |record| {
        record.* = self.context.projection.model.tabs.location[slot].tab_id;
    }
}

fn drawTabs(self: TabStrip, canvas: *Canvas, row: Rect, laid: Laid) !f32 {
    const layout = laid.layout.*;
    const model = self.context.projection.model;
    const collection = &model.tabs;
    const chrome = canvas.chrome;
    const gap = chrome.px(strip_gap);
    var order: [max_tabs]usize = undefined;
    for (layout.first..layout.end, 0..) |index, position| {
        order[position] = index;
    }

    const shown = order[0 .. layout.end - layout.first];
    if (canvas.widgets) |widgets| {
        const drag = &widgets.tab_drag;
        const preview: ?client.TabMoveIntent = if (drag.source != null and drag.destination != null)
            .{ .location = drag.source.?, .relative_to = drag.destination.?.relative_to, .direction = drag.destination.?.direction }
        else
            widgets.tab_drop_pending;
        if (preview) |move| {
            previewOrder(shown, model, move);
        }
    }

    var x = row.x;
    var lifted: ?Painted = null;
    for (shown, 0..) |index, position| {
        const tab_id = collection.location[index].tab_id;
        if (position != 0) {
            x += gap;
        }

        var bounds: Rect = .{ .x = x, .y = row.y, .width = layout.widths[index], .height = row.height };
        var dragging = false;
        if (canvas.widgets) |widgets| {
            const drag = &widgets.tab_drag;
            dragging = drag.dragging and drag.source != null and drag.source.?.tab_id == tab_id;
            if (dragging) {
                if (drag.destination != null) {
                    try canvas.ringAt(bounds, .{ .color = canvas.theme.palette.surface1, .width = chrome.px(1), .radius = chrome.px(pill_radius) });
                }

                bounds.x = @floatCast(std.math.clamp(widgets.tab_pointer[0] - widgets.tab_grab_offset, self.area.x, @max(self.area.x, row.x + row.width - bounds.width)));
                bounds.y -= chrome.px(3);
            }

            if (canvas.animation) |clock| {
                bounds = widgets.tab_motions.place(.{ .id = tab_id, .bounds = bounds, .immediate = dragging }, clock);
            }
        }

        const painted: Painted = .{
            .index = index,
            .bounds = bounds,
            .fit = layout.fits[index],
            .size = laid.sizes[index],
        };
        if (dragging) {
            lifted = painted;
        } else {
            try self.drawTab(canvas, painted);
        }

        x += layout.widths[index];
    }

    if (lifted) |entry| {
        try self.drawTab(canvas, entry);
        try canvas.ringAt(entry.bounds, .{ .color = canvas.theme.palette.accent, .width = chrome.px(1), .radius = chrome.px(pill_radius) });
    }

    if (layout.hidden() > 0) {
        x += gap;
        const width = @min(chrome.px(counter_width), @max(0, row.x + row.width - x));
        try self.drawCounter(canvas, .{ .x = x, .y = row.y, .width = width, .height = row.height }, laid.layout);
        x += width;
    }

    return x + gap;
}

fn drawTab(self: TabStrip, canvas: *Canvas, entry: Painted) !void {
    const index = entry.index;
    const bounds = entry.bounds;
    const context = self.context;
    const model = context.projection.model;
    const location = model.tabs.location[index];
    const palette = canvas.theme.palette;
    const chrome = canvas.chrome;
    const selected = index == model.tabs.active;
    const action: action_module.Action = .{ .intent = .{ .select_tab = location.tab_id } };
    const hovered = context.isHovered(action);
    const first = canvas.quads.items().len;
    if (selected or hovered) {
        try canvas.fillRoundedAt(bounds, .{ .radius = chrome.px(pill_radius), .color = if (selected) palette.surface1 else palette.surface0 });
    }

    const size = entry.size;
    const status = self.statusOf(index, palette);
    const status_right = bounds.x + bounds.width - chrome.px(if (entry.fit == .compact) lead else trail);
    const chip_width = @max(0, @min(size.chip, bounds.width - 2 * chrome.px(lead)));
    const chip: Rect = .{ .x = bounds.x + chrome.px(lead), .y = bounds.y + (bounds.height - chip_width) / 2, .width = chip_width, .height = chip_width };
    try self.drawChip(canvas, chip, .{ .index = index, .lit = selected or hovered });

    if (entry.fit != .compact) {
        var storage: [caption_capacity]u8 = undefined;
        const label: Label = .{
            .text = self.caption(&storage, index),
            .color = if (selected or hovered) palette.text else palette.subtext0,
            .face = .sans,
            .size = .body,
        };
        const x = chip.x + chip.width + chrome.px(spacing);
        const right = status_right - (if (size.status > 0) size.status + chrome.px(spacing) else 0);
        const room = @max(0, right - x);
        const caption_first = canvas.quads.items().len;
        _ = try canvas.textAt(.{ .x = x, .y = bounds.y, .width = room, .height = bounds.height }, label);
        if (size.caption > room) {
            canvas.quads.fadeEdgeFrom(caption_first, .{ .from = @max(x, right - chrome.px(fade_width)), .to = right });
        }
    }

    if (size.status > 0) {
        const slot: Rect = .{ .x = status_right - size.status, .y = bounds.y, .width = size.status, .height = bounds.height };
        try self.drawStatus(canvas, slot, status);
    }

    canvas.quads.clipFrom(first, bounds);
    context.bands.add(.{ .area = bounds, .action = action });
}

// The chip holds the application's mark, or the tab's number while the
// prefix waits for a digit, so the numbers never change a tab's width.
fn drawChip(self: TabStrip, canvas: *Canvas, chip: Rect, tab: ChipTab) !void {
    if (chip.width <= 0) {
        return;
    }

    const palette = canvas.theme.palette;
    const chrome = canvas.chrome;
    const selected = tab.index == self.context.projection.model.tabs.active;
    try canvas.fillRoundedAt(chip, .{ .radius = chrome.px(chip_radius), .color = palette.text, .alpha = if (selected) chip_selected_alpha else chip_alpha });
    if (std.meta.activeTag(self.context.projection.status_mode) == .prefix) {
        var storage: [8]u8 = undefined;
        const number: Label = .{
            .text = std.fmt.bufPrint(&storage, "{d}", .{tab.index + 1}) catch unreachable,
            .color = palette.text,
            .bold = true,
            .face = .sans,
            .size = .small,
        };
        const width = @min(chip.width, try canvas.measure(number));
        _ = try canvas.textAt(.{ .x = chip.x + (chip.width - width) / 2, .y = chip.y, .width = width, .height = chip.height }, number);
        return;
    }

    const side = @min(chip.width, chrome.px(mark_side));
    const mark = data.tab_label.mark(self.context.projection.model, tab.index);
    try application_mark.draw(canvas, mark, .{ .x = chip.x + (chip.width - side) / 2, .y = chip.y + (chip.height - side) / 2, .width = side, .height = side }, !tab.lit);
}

fn drawStatus(self: TabStrip, canvas: *Canvas, slot: Rect, status: Status) !void {
    const chrome = canvas.chrome;
    switch (status) {
        .none => {},
        .dot => |color| {
            const side = @min(chrome.px(dot_side), slot.width);
            try canvas.fillRoundedAt(.{ .x = slot.x + slot.width - side, .y = slot.y + (slot.height - side) / 2, .width = side, .height = side }, .{ .radius = side / 2, .color = color });
        },
        .spinner => {
            const side = @min(chrome.px(spinner_side), slot.width);
            const step = if (canvas.animation) |clock| clock.step(spinner_step_ns) % spinner_steps else 0;
            const ring: ProgressRing = .{
                .area = .{ .x = slot.x + slot.width - side, .y = slot.y + (slot.height - side) / 2, .width = side, .height = side },
                .color = canvas.theme.palette.teal,
                .fraction = spinner_fraction,
                .rotation = @as(f32, @floatFromInt(step)) / spinner_steps,
            };
            try ring.draw(canvas);
        },
        .progress => |pane| {
            const progress: PaneProgress = .{ .pane = pane, .area = slot, .compact = true, .motions = self.context.progress };
            try progress.draw(canvas);
        },
    }
}

fn drawCounter(self: TabStrip, canvas: *Canvas, bounds: Rect, layout: *const Plan) !void {
    const model = self.context.projection.model;
    const palette = canvas.theme.palette;
    const left_distance = if (layout.first > 0) layout.focus - (layout.first - 1) else std.math.maxInt(usize);
    const right_distance = if (layout.end < model.tabs.count) layout.end - layout.focus else std.math.maxInt(usize);
    const nearest = if (left_distance <= right_distance) layout.first - 1 else layout.end;
    var storage: [8]u8 = undefined;
    var urgent: ?cellgrid.Color = null;
    for (0..model.tabs.count) |index| {
        if (index >= layout.first and index < layout.end) {
            continue;
        }

        if (attention.tabDot(self.context.projection, palette, model.tabs.location[index])) |color| {
            urgent = color;
        }
    }

    const counter: PixelButton = .{
        .context = self.context,
        .area = bounds,
        .intent = .{ .select_tab = model.tabs.location[nearest].tab_id },
        .text = std.fmt.bufPrint(&storage, "+{d}", .{layout.hidden()}) catch unreachable,
        .alignment = .center,
        .background = false,
        .hover_fill = true,
        .size = .small,
        .radius = canvas.chrome.px(pill_radius),
        .dot = urgent,
    };
    try counter.draw(canvas);
}

const caption_capacity = data.tab_label.caption_bytes + fullscreen_suffix.len;
const fullscreen_suffix = " \u{26f6}";

fn caption(self: TabStrip, storage: *[caption_capacity]u8, index: usize) []const u8 {
    const model = self.context.projection.model;
    var shown: [data.tab_label.caption_bytes]u8 = undefined;
    const text = data.tab_label.caption(model, index, &shown);
    const suffix = if (model.tabs.layout[index].isFullscreen()) fullscreen_suffix else "";
    return std.fmt.bufPrint(storage, "{s}{s}", .{ text, suffix }) catch unreachable;
}

fn measure(self: TabStrip, canvas: *Canvas, index: usize) !Measure {
    var storage: [caption_capacity]u8 = undefined;
    return .{
        .caption = try canvas.measure(.{ .text = self.caption(&storage, index), .face = .sans, .size = .body }),
        .chip = canvas.chrome.px(chip_side),
        .status = try statusWidth(canvas, self.statusOf(index, canvas.theme.palette)),
    };
}

fn statusWidth(canvas: *Canvas, status: Status) !f32 {
    return switch (status) {
        .none => 0,
        .dot => canvas.chrome.px(dot_side),
        .spinner => canvas.chrome.px(spinner_side),
        .progress => |pane| try (PaneProgress{ .pane = pane, .area = .{ .x = 0, .y = 0, .width = 0, .height = 0 }, .compact = true }).width(canvas),
    };
}

// What the trailing slot shows: the selected pane's own progress report,
// else the most urgent agent of the tab. Idle agents show nothing.
fn statusOf(self: TabStrip, index: usize, palette: data.Palette) Status {
    const projection = self.context.projection;
    const model = projection.model;
    if (index == model.tabs.active and model.tabs.layout[index].count() == 1) {
        if (data.tab_layout.focusedPaneConst(model, index)) |pane| {
            if (pane.progress_state != .remove) {
                return .{ .progress = pane };
            }
        }
    }

    const agent = attention.tabAgent(projection, model.tabs.location[index]) orelse return .none;
    return switch (agent.status) {
        .working => .spinner,
        .blocked, .failed, .done => .{ .dot = attention.statusColor(palette, agent.status) },
        .ready, .unknown => .none,
    };
}

/// Keeps the active tab visible: walks back from it while earlier tabs fit.
/// Example: `const first = firstVisible(model.tabs.active, widths, .{ .available = room, .gap = 2 });`
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

fn previewOrder(order: []usize, model: *const data.ClientModel, move: client.TabMoveIntent) void {
    if (!std.meta.eql(model.workspace, @as(?core.WorkspaceLocation, move.location.workspace))) {
        return;
    }

    var source: ?usize = null;
    var anchor: ?usize = null;
    for (order, 0..) |index, position| {
        const tab_id = model.tabs.location[index].tab_id;
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

/// How much of a tab is left after compression, from its whole caption down
/// to its chip alone.
const Fit = enum { full, truncated, compact };

const Status = union(enum) {
    none,
    dot: cellgrid.Color,
    spinner,
    progress: *const data.Pane,
};

/// Which tab a chip belongs to and whether its mark is at full strength.
const ChipTab = struct {
    index: usize,
    lit: bool,
};

const Painted = struct {
    index: usize,
    bounds: Rect,
    fit: Fit,
    size: Measure,
};

/// One frame's plan with the measurements it was made from.
const Laid = struct {
    layout: *const Plan,
    sizes: []const Measure,
};

/// Strip lengths already scaled to device pixels.
const Metrics = struct {
    lead: f32,
    trail: f32,
    spacing: f32,
    gap: f32,
    inactive_max: f32,
    selected_max: f32,
    caption_min: f32,
    counter: f32,

    fn of(chrome: ChromeMetrics) Metrics {
        return .{
            .lead = chrome.px(lead),
            .trail = chrome.px(trail),
            .spacing = chrome.px(spacing),
            .gap = chrome.px(strip_gap),
            .inactive_max = chrome.px(inactive_max),
            .selected_max = chrome.px(selected_max),
            .caption_min = chrome.px(caption_min),
            .counter = chrome.px(counter_width),
        };
    }
};

/// The measured parts of one tab, in device pixels.
const Measure = struct {
    caption: f32,
    chip: f32,
    status: f32,

    fn trailing(self: Measure, metrics: Metrics) f32 {
        return if (self.status > 0) metrics.spacing + self.status else 0;
    }

    fn whole(self: Measure, metrics: Metrics) f32 {
        return metrics.lead + self.chip + metrics.spacing + self.caption + self.trailing(metrics) + metrics.trail;
    }

    fn truncated(self: Measure, metrics: Metrics) f32 {
        return @min(self.whole(metrics), metrics.lead + self.chip + metrics.spacing + metrics.caption_min + self.trailing(metrics) + metrics.trail);
    }

    fn compact(self: Measure, metrics: Metrics) f32 {
        return 2 * metrics.lead + self.chip + self.trailing(metrics);
    }
};

/// The tabs that keep a caption and the room they share.
const Share = struct {
    captioned: *const [max_tabs]bool,
    budget: f32,
};

const Room = struct {
    room: f32,
    metrics: Metrics,
};

/// Widths and fits of every tab plus the contiguous run left visible.
const Plan = struct {
    widths: [max_tabs]f32 = @splat(0),
    fits: [max_tabs]Fit = @splat(.full),
    first: usize = 0,
    end: usize = 0,
    focus: usize = 0,
    count: usize = 0,

    fn hidden(self: Plan) usize {
        return self.count - (self.end - self.first);
    }

    fn shows(self: Plan, index: usize) bool {
        return index >= self.first and index < self.end;
    }
};

// Lays the tabs out around `focus`. The focus takes its whole caption up to
// a share of the room; the rest share what is left at the richest fit that
// holds all of them, and only below the chip alone do the farthest tabs hide.
fn plan(sizes: []const Measure, focus: usize, room: Room) Plan {
    const metrics = room.metrics;
    const count = sizes.len;
    var result: Plan = .{ .first = 0, .end = count, .focus = focus, .count = count };
    const focus_whole = sizes[focus].whole(metrics);
    const focus_width = @max(sizes[focus].compact(metrics), @min(focus_whole, @min(metrics.selected_max, room.room * selected_share)));
    result.widths[focus] = focus_width;
    result.fits[focus] = if (focus_width >= focus_whole) .full else .truncated;
    const budget = room.room - focus_width - metrics.gap * @as(f32, @floatFromInt(count - 1));
    var natural: f32 = 0;
    var shortest: f32 = 0;
    for (sizes, 0..) |size, index| {
        if (index == focus) {
            continue;
        }

        natural += @min(size.whole(metrics), metrics.inactive_max);
        shortest += @min(size.truncated(metrics), metrics.inactive_max);
    }

    if (natural <= budget) {
        for (sizes, 0..) |size, index| {
            if (index != focus) {
                result.widths[index] = @min(size.whole(metrics), metrics.inactive_max);
                result.fits[index] = if (size.whole(metrics) <= metrics.inactive_max) .full else .truncated;
            }
        }

        return result;
    }

    // Every other tab starts as its chip; the nearest to the focus take back
    // a caption while the budget allows, so no room is left unused.
    var captioned: [max_tabs]bool = @splat(shortest <= budget);
    captioned[focus] = false;
    if (shortest > budget) {
        var used: f32 = 0;
        for (sizes, 0..) |size, index| {
            if (index != focus) {
                used += size.compact(metrics);
            }
        }

        var distance: usize = 1;
        while (distance < count) : (distance += 1) {
            for ([_]?usize{ if (focus >= distance) focus - distance else null, if (focus + distance < count) focus + distance else null }) |candidate| {
                const index = candidate orelse continue;
                const extra = @min(sizes[index].truncated(metrics), metrics.inactive_max) - sizes[index].compact(metrics);
                if (used + extra <= budget) {
                    captioned[index] = true;
                    used += extra;
                }
            }
        }
    }

    var fixed: f32 = 0;
    for (sizes, 0..) |size, index| {
        if (index != focus and !captioned[index]) {
            result.widths[index] = size.compact(metrics);
            result.fits[index] = .compact;
            fixed += size.compact(metrics);
        }
    }

    const cap = largestCap(sizes, .{ .captioned = &captioned, .budget = budget - fixed }, metrics);
    for (sizes, 0..) |size, index| {
        if (captioned[index]) {
            const floor = @min(size.truncated(metrics), metrics.inactive_max);
            const width = @floor(@max(floor, @min(@min(size.whole(metrics), metrics.inactive_max), cap)));
            result.widths[index] = width;
            result.fits[index] = if (width >= size.whole(metrics)) .full else .truncated;
        }
    }

    if (shortest <= budget) {
        return result;
    }

    while (footprint(result, metrics) > room.room and result.end - result.first > 1) {
        if (result.end - 1 - focus >= focus - result.first) {
            result.end -= 1;
        } else {
            result.first += 1;
        }
    }

    return result;
}

// The largest per-tab cap at which the captioned tabs' capped widths still
// fit their budget, found by bisection so it never depends on tab order.
fn largestCap(sizes: []const Measure, share: Share, metrics: Metrics) f32 {
    var low: f32 = 0;
    var high = metrics.inactive_max;
    for (0..cap_steps) |_| {
        const cap = (low + high) / 2;
        var used: f32 = 0;
        for (sizes, 0..) |size, index| {
            if (share.captioned[index]) {
                used += @max(@min(size.truncated(metrics), metrics.inactive_max), @min(@min(size.whole(metrics), metrics.inactive_max), cap));
            }
        }

        if (used <= share.budget) {
            low = cap;
        } else {
            high = cap;
        }
    }

    return low;
}

fn footprint(layout: Plan, metrics: Metrics) f32 {
    var used: f32 = 0;
    for (layout.first..layout.end) |index| {
        used += layout.widths[index];
    }

    used += metrics.gap * @as(f32, @floatFromInt(layout.end - layout.first - 1));
    if (layout.hidden() > 0) {
        used += metrics.gap + metrics.counter;
    }

    return used;
}

const test_metrics: Metrics = .{
    .lead = 5,
    .trail = 12,
    .spacing = 8,
    .gap = 2,
    .inactive_max = 220,
    .selected_max = 300,
    .caption_min = 56,
    .counter = 36,
};

fn testSizes(comptime count: usize, caption_width: f32) [count]Measure {
    return @splat(.{
        .caption = caption_width,
        .chip = 20,
        .status = 0,
    });
}

test "tabs that fit keep their whole captions and the selection its full width" {
    const sizes = testSizes(3, 100);
    const layout = plan(&sizes, 1, .{ .room = 1000, .metrics = test_metrics });
    for (0..3) |index| {
        try std.testing.expectEqual(Fit.full, layout.fits[index]);
        try std.testing.expectEqual(sizes[index].whole(test_metrics), layout.widths[index]);
    }

    try std.testing.expectEqual(@as(usize, 0), layout.hidden());
}

test "narrower rooms truncate the captions, then keep only the chips around the selection" {
    const sizes = testSizes(8, 120);
    const whole = sizes[0].whole(test_metrics);
    const truncated = plan(&sizes, 2, .{ .room = 1100, .metrics = test_metrics });
    try std.testing.expectEqual(Fit.full, truncated.fits[2]);
    try std.testing.expectEqual(whole, truncated.widths[2]);
    try std.testing.expectEqual(Fit.truncated, truncated.fits[0]);
    try std.testing.expect(truncated.widths[0] < whole and truncated.widths[0] >= sizes[0].truncated(test_metrics));
    try std.testing.expect(footprint(truncated, test_metrics) <= 1100);

    const compact = plan(&sizes, 2, .{ .room = 420, .metrics = test_metrics });
    try std.testing.expectEqual(Fit.compact, compact.fits[0]);
    try std.testing.expectEqual(sizes[0].compact(test_metrics), compact.widths[0]);
    try std.testing.expectEqual(@as(usize, 0), compact.hidden());
    try std.testing.expect(footprint(compact, test_metrics) <= 420);
}

test "past the chips the tabs farthest from the selection hide behind the counter" {
    const sizes = testSizes(8, 120);
    const layout = plan(&sizes, 2, .{ .room = 250, .metrics = test_metrics });
    try std.testing.expect(layout.hidden() > 0);
    try std.testing.expect(layout.first <= 2 and 2 < layout.end);
    try std.testing.expect(footprint(layout, test_metrics) <= 250);
    try std.testing.expect(layout.end - 1 - 2 <= 2 - layout.first + 1);
}

test "the selection never takes more than its share of a narrow strip" {
    const sizes = testSizes(2, 400);
    const layout = plan(&sizes, 0, .{ .room = 400, .metrics = test_metrics });
    try std.testing.expectEqual(Fit.truncated, layout.fits[0]);
    try std.testing.expectEqual(@as(f32, 400 * selected_share), layout.widths[0]);
}

test "a strip too narrow for every caption keeps captions next to the selection and chips further away" {
    const sizes = testSizes(8, 120);
    const layout = plan(&sizes, 3, .{ .room = 700, .metrics = test_metrics });
    try std.testing.expectEqual(Fit.full, layout.fits[3]);
    try std.testing.expect(layout.fits[2] != .compact and layout.fits[4] != .compact);
    try std.testing.expectEqual(Fit.compact, layout.fits[7]);
    try std.testing.expectEqual(@as(usize, 0), layout.hidden());
    try std.testing.expect(footprint(layout, test_metrics) <= 700);
    // No room a truncated caption could use is left over.
    try std.testing.expect(700 - footprint(layout, test_metrics) < sizes[7].truncated(test_metrics) - sizes[7].compact(test_metrics));
}
