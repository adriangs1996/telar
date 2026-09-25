//! Native command history: a panel above the status bar with the search
//! field at its foot, the newest command right above the filter chips, day
//! headings over the list, an inspector beside it and the host's key hints
//! in the footer. It shares query and selection semantics with the TUI.
const std = @import("std");
const cellgrid = @import("cellgrid");
const client = @import("telar-client");
const core = @import("telar-core");
const data = @import("model");
const Canvas = @import("../Canvas.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const TextField = @import("../TextField.zig");
const FormButton = @import("../FormButton.zig");
const HistoryDetails = @import("HistoryDetails.zig");
const HistoryLine = @import("HistoryLine.zig");
const Metrics = @import("HistoryModalMetrics.zig");
const Layout = @import("HistoryModalLayout.zig");
const DialogSurface = @import("DialogSurface.zig");
const Label = @import("../Label.zig");
const HistoryRow = @import("HistoryRow.zig");
const Caption = @import("../Caption.zig");
const Target = @import("../interaction/Target.zig");
const HistoryChoice = @import("../interaction/HistoryChoice.zig");
const key_label = @import("key_label.zig");
const labels = @import("history_labels.zig");
const HistoryModal = @This();

/// Rows plus headings the list can place at its smallest row height.
const max_placements = 96;
/// The search glyph of the embedded symbols face.
const search_glyph = "\u{f002}";
/// Steps of the indeterminate loading line under the chips.
const loading_steps: u64 = 40;
const loading_step_ns: u64 = 24 * std.time.ns_per_ms;

layout: Layout,
projection: *const client.Projection,
reveal: f32 = 1,

/// All controls use the same animated pixel layout as the painted surface.
/// Example: `try widget.draw(canvas);`
pub fn draw(self: HistoryModal, canvas: *Canvas) !void {
    const first = canvas.quads.items().len;
    try (DialogSurface{ .bounds = self.layout.bounds, .viewport = self.layout.viewport }).draw(canvas);
    const content = canvas.quads.items().len;
    const prompt = self.projection.prompt.?;
    if (self.projection.history.len == 0) {
        try self.empty(canvas);
    } else {
        try self.rows(canvas);
        if (prompt.inspecting()) {
            try self.inspect(canvas);
        }
    }

    try self.chips(canvas);
    try self.search(canvas);
    try self.footer(canvas);
    canvas.quads.clipFrom(content, self.layout.bounds);
    canvas.quads.clipFrom(first, self.layout.viewport);
    canvas.quads.fadeFrom(first, self.reveal);
}

/// Counts exactly the native inspector's lines, without shaping text.
/// Example: `const limit = HistoryModal.inspectionScrollLimit(projection, metrics);`
pub fn inspectionScrollLimit(projection: client.Projection, metrics: Metrics) ?u32 {
    const prompt = projection.prompt orelse return null;
    const history = projection.history;
    if (prompt.target() != .history or !prompt.inspecting() or prompt.detailScroll() == 0 or history.phase != .ready or history.len == 0) {
        return null;
    }

    const content = Layout.measure(metrics, true).inspectionContent(metrics);
    const columns = columnsFor(content, metrics);
    const rows_count: u32 = @intFromFloat(@floor(content.height / @as(f32, @floatFromInt(@max(1, metrics.terminal.cell_height)))));
    const details = HistoryDetails.init(&projection, @min(prompt.selection(), history.len - 1));
    return details.lines(columns).count() -| rows_count;
}

// ---------------------------------------------------------------------------
// The list
// ---------------------------------------------------------------------------

const PlacementKind = enum { row, heading, older };

const Placement = struct {
    kind: PlacementKind,
    index: u16 = 0,
    y: f32,
};

const Plan = struct {
    placements: [max_placements]Placement = undefined,
    count: usize = 0,
    /// Every entry from the bottom index to the oldest was placed.
    complete: bool = false,

    fn contains(self: *const Plan, index: u16) bool {
        for (self.placements[0..self.count]) |placement| {
            if (placement.kind == .row and placement.index == index) {
                return true;
            }
        }

        return false;
    }
};

const PlaceInput = struct {
    list: Rect,
    bottom: u16,
    grouped: bool,
};

fn rows(self: HistoryModal, canvas: *Canvas) !void {
    const layout = self.layout;
    const list = layout.results;
    if (list.width <= 0 or list.height <= 0) {
        return;
    }

    const history = self.projection.history;
    const prompt = self.projection.prompt.?;
    const selected: u16 = @min(prompt.selection(), history.len - 1);
    const grouped = self.queryFilters().query.len == 0;
    var plan: Plan = .{};
    var bottom: u16 = 0;
    self.place(canvas, .{ .list = list, .bottom = bottom, .grouped = grouped }, &plan);
    while (!plan.contains(selected) and bottom < selected) {
        bottom += 1;
        self.place(canvas, .{ .list = list, .bottom = bottom, .grouped = grouped }, &plan);
    }

    const first = canvas.quads.items().len;
    const show_cwd = history.effective_scope == .global or history.effective_scope == .workspace;
    for (plan.placements[0..plan.count]) |placement| {
        switch (placement.kind) {
            .row => try (HistoryRow{
                .bounds = .{ .x = list.x, .y = placement.y, .width = list.width, .height = layout.row_height },
                .projection = self.projection,
                .index = placement.index,
                .selected = placement.index == selected,
                .time = if (grouped) .clock else .date,
                .show_cwd = show_cwd,
            }).draw(canvas),
            .heading => try self.heading(canvas, placement),
            .older => try self.olderRow(canvas, placement.y),
        }
    }

    if (history.phase == .loading) {
        canvas.quads.fadeFrom(first, 0.55);
    }

    canvas.quads.clipFrom(first, list);
}

// Places rows from the bottom up: the newest of the window sits on the
// chips, each day's heading goes above its oldest row, and the "older"
// row appears only when the whole page fits.
fn place(self: HistoryModal, canvas: *const Canvas, input: PlaceInput, plan: *Plan) void {
    const history = self.projection.history;
    const layout = self.layout;
    plan.* = .{};
    var y = input.list.y + input.list.height - canvas.chrome.px(4);
    var index = input.bottom;
    while (index < history.len and plan.count < max_placements) : (index += 1) {
        if (y - layout.row_height < input.list.y) {
            break;
        }

        y -= layout.row_height;
        plan.placements[plan.count] = .{ .kind = .row, .index = index, .y = y };
        plan.count += 1;
        if (!input.grouped) {
            continue;
        }

        const day = self.dayOf(index);
        const closes_group = index + 1 >= history.len or self.dayOf(index + 1) != day;
        if (!closes_group) {
            continue;
        }
        if (y - layout.group_height < input.list.y or plan.count == max_placements) {
            break;
        }

        y -= layout.group_height;
        plan.placements[plan.count] = .{ .kind = .heading, .index = index, .y = y };
        plan.count += 1;
    }

    plan.complete = index == history.len;
    if (plan.complete and history.has_more and plan.count < max_placements and y - layout.row_height >= input.list.y) {
        y -= layout.row_height;
        plan.placements[plan.count] = .{ .kind = .older, .y = y };
        plan.count += 1;
    }
}

fn dayOf(self: HistoryModal, index: u16) i64 {
    const history = self.projection.history;
    return labels.localDay(history.slice()[index].started_at_ms, history.utc_offset_min);
}

fn heading(self: HistoryModal, canvas: *Canvas, placement: Placement) !void {
    const history = self.projection.history;
    const list = self.layout.results;
    const px = canvas.chrome;
    var storage: [32]u8 = undefined;
    var upper: [32]u8 = undefined;
    const day = self.dayOf(placement.index);
    const today = labels.localDay(history.now_ms, history.utc_offset_min);
    const text = labels.dayLabel(day, today, &storage);
    _ = try canvas.textAt(.{
        .x = list.x + px.px(18),
        .y = placement.y,
        .width = @max(0, list.width - px.px(36)),
        .height = self.layout.group_height,
    }, .{
        .text = std.ascii.upperString(&upper, text),
        .face = .sans,
        .size = .small,
        .bold = true,
        .color = canvas.theme.palette.subtext0,
    });
}

fn olderRow(self: HistoryModal, canvas: *Canvas, y: f32) !void {
    const list = self.layout.results;
    const px = canvas.chrome;
    const palette = canvas.theme.palette;
    const history = self.projection.history;
    const bounds: Rect = .{
        .x = list.x + px.px(8),
        .y = y + px.px(1),
        .width = @max(0, list.width - px.px(16)),
        .height = @max(0, self.layout.row_height - px.px(2)),
    };
    var hovered = false;
    if (canvas.widgets) |state| {
        const target = (Target{
            .id = .{ .generation = self.projection.prompt.?.generation },
            .bounds = bounds,
            .action = .{ .history = .page_older },
            .layer = 1,
            .focusable = false,
            .enabled = history.phase == .ready,
        }).labelled("Older commands");
        const id = try state.dispatcher.add(target);
        hovered = if (state.dispatcher.hovered) |hover| hover.eql(id) else false;
    }

    if (hovered) {
        try canvas.fillRoundedAt(bounds, .{ .color = palette.surface0, .radius = px.px(8) });
    }

    const key = keyText(.page_up);
    const glyph_width = px.px(20);
    _ = try canvas.textAt(.{
        .x = bounds.x + px.px(10),
        .y = bounds.y,
        .width = glyph_width,
        .height = bounds.height,
    }, .{
        .text = if (key_label.host_style == .mac) "⇞" else "↑",
        .color = palette.overlay1,
    });
    const label: Label = .{ .text = "Older commands", .face = .sans, .size = .body, .color = palette.subtext0 };
    const width = try canvas.textAt(.{
        .x = bounds.x + px.px(10) + glyph_width + px.px(10),
        .y = bounds.y,
        .width = @max(0, bounds.width - glyph_width - px.px(30)),
        .height = bounds.height,
    }, label);
    _ = try canvas.textAt(.{
        .x = bounds.x + px.px(10) + glyph_width + px.px(10) + width + px.px(10),
        .y = bounds.y,
        .width = @max(0, bounds.width - glyph_width - width - px.px(40)),
        .height = bounds.height,
    }, .{
        .text = key,
        .color = palette.overlay1,
    });
}

// ---------------------------------------------------------------------------
// Empty states
// ---------------------------------------------------------------------------

fn empty(self: HistoryModal, canvas: *Canvas) !void {
    const layout = self.layout;
    const history = self.projection.history;
    const palette = canvas.theme.palette;
    const px = canvas.chrome;
    const area = if (layout.results.width > 0) layout.results else layout.inspection;
    if (area.width <= 0 or area.height <= 0) {
        return;
    }

    const filters = self.queryFilters();
    const title_height = px.rowHeight(.body);
    const small_height = px.rowHeight(.small);
    const stack = title_height + px.px(6) + small_height + px.px(14) + px.px(28);
    const top = area.y + @max(0, (area.height - stack) / 2);
    const inner: Rect = .{
        .x = area.x + px.px(16),
        .y = top,
        .width = @max(0, area.width - px.px(32)),
        .height = title_height,
    };
    if (history.initialLoading()) {
        try centered(canvas, inner, .{ .text = "Searching your command history…", .face = .sans, .size = .body, .color = palette.text });
        return;
    }
    if (history.phase == .failed) {
        try centered(canvas, inner, .{ .text = "Could not load the command history", .face = .sans, .size = .body, .color = palette.text });
        return;
    }

    const nothing_recorded = filters.query.len == 0 and history.effective_scope == .global and filters.author == .all and !filters.failed_only and history.page_offset == 0;
    var storage: [96]u8 = undefined;
    const title = if (nothing_recorded) "No commands yet" else switch (history.effective_scope) {
        .global => "No matching commands",
        .workspace => std.fmt.bufPrint(&storage, "No matches in workspace {s}", .{self.projection.model.workspaceName()}) catch "No matches in this workspace",
        .cwd => "No matches in this directory",
        .pane => "No matches in this pane",
    };
    try centered(canvas, inner, .{ .text = title, .face = .sans, .size = .body, .bold = true, .color = palette.text });
    const subtitle: Rect = .{
        .x = inner.x,
        .y = inner.y + title_height + px.px(6),
        .width = inner.width,
        .height = small_height,
    };
    try centered(canvas, subtitle, .{
        .text = if (nothing_recorded) "Commands you run in telar appear here as you work. Bring your shell history:" else "Widen the search or check the filters.",
        .face = .sans,
        .size = .small,
        .color = palette.subtext0,
    });
    const action_y = subtitle.y + small_height + px.px(14);
    if (nothing_recorded) {
        const label: Label = .{ .text = "telar history import", .color = palette.text };
        const width = @min(inner.width, try canvas.measure(label) + px.px(20));
        const chip: Rect = .{
            .x = inner.x + @max(0, (inner.width - width) / 2),
            .y = action_y,
            .width = width,
            .height = px.px(28),
        };
        try canvas.fillRoundedAt(chip, .{ .color = palette.surface0, .radius = px.px(4) });
        _ = try canvas.textAt(.{
            .x = chip.x + px.px(10),
            .y = chip.y,
            .width = @max(0, chip.width - px.px(20)),
            .height = chip.height,
        }, label);
        return;
    }
    if (history.effective_scope == .global) {
        return;
    }

    const width = @min(inner.width, px.px(180));
    try (FormButton{
        .bounds = .{ .x = inner.x + @max(0, (inner.width - width) / 2), .y = action_y, .width = width, .height = px.px(28) },
        .text = "Search everywhere",
        .action = .{ .history = .{ .select_scope = .global } },
        .generation = self.projection.prompt.?.generation,
        .namespace = 4,
    }).draw(canvas);
}

fn centered(canvas: *Canvas, area: Rect, label: Label) !void {
    const width = @min(area.width, try canvas.measure(label));
    _ = try canvas.textAt(.{
        .x = area.x + @max(0, (area.width - width) / 2),
        .y = area.y,
        .width = width,
        .height = area.height,
    }, label);
}

// ---------------------------------------------------------------------------
// Chips
// ---------------------------------------------------------------------------

const Chip = struct {
    bounds: Rect,
    text: []const u8,
    value: []const u8 = "",
    action: Target.Action,
    generation: u64,
    selected: bool,
    danger: bool = false,

    fn width(canvas: *Canvas, text: []const u8, value: []const u8) !f32 {
        const px = canvas.chrome;
        var total = try canvas.measure(.{ .text = text, .face = .sans, .size = .small }) + px.px(20);
        if (value.len != 0) {
            total += try canvas.measure(.{ .text = value, .face = .sans, .size = .small }) + px.px(6);
        }

        return total;
    }

    fn draw(self: Chip, canvas: *Canvas) !void {
        const palette = canvas.theme.palette;
        const px = canvas.chrome;
        var hovered = false;
        if (canvas.widgets) |state| {
            const target = (Target{
                .id = .{ .generation = self.generation },
                .bounds = self.bounds,
                .action = self.action,
                .layer = 1,
                .focusable = false,
            }).labelled(self.text);
            const id = try state.dispatcher.add(target);
            hovered = if (state.dispatcher.hovered) |hover| hover.eql(id) else false;
        }

        if (self.selected or hovered) {
            try canvas.fillRoundedAt(self.bounds, .{ .color = palette.surface1, .radius = px.px(4) });
        }
        if (self.danger and self.selected) {
            try canvas.ringAt(self.bounds, .{ .color = palette.red, .width = px.px(1), .radius = px.px(4), .alpha = 0.8 });
        }

        const color = if (self.danger and self.selected) palette.red else if (self.selected) palette.text else palette.subtext0;
        var x = self.bounds.x + px.px(10);
        const painted = try canvas.textAt(.{
            .x = x,
            .y = self.bounds.y,
            .width = @max(0, self.bounds.width - px.px(20)),
            .height = self.bounds.height,
        }, .{ .text = self.text, .face = .sans, .size = .small, .color = color });
        if (self.value.len != 0) {
            x += painted + px.px(6);
            _ = try canvas.textAt(.{
                .x = x,
                .y = self.bounds.y,
                .width = @max(0, self.bounds.x + self.bounds.width - px.px(10) - x),
                .height = self.bounds.height,
            }, .{ .text = self.value, .face = .sans, .size = .small, .color = palette.accent });
        }
    }
};

const scope_chips = [_]struct { scope: data.PromptHistoryScope, text: []const u8 }{
    .{ .scope = .global, .text = "All" },
    .{ .scope = .workspace, .text = "Workspace" },
    .{ .scope = .cwd, .text = "Directory" },
    .{ .scope = .pane, .text = "Pane" },
};

const author_chips = [_]struct { author: core.HistoryAuthorFilter, text: []const u8 }{
    .{ .author = .human, .text = "You" },
    .{ .author = .agent, .text = "Agents" },
    .{ .author = .all, .text = "Both" },
};

fn chips(self: HistoryModal, canvas: *Canvas) !void {
    const area = self.layout.chips;
    if (area.height <= 0 or area.width <= 0) {
        return;
    }

    const palette = canvas.theme.palette;
    const px = canvas.chrome;
    const prompt = self.projection.prompt.?;
    const history = self.projection.history;
    const filters = self.queryFilters();
    try canvas.fillAt(.{ .x = area.x, .y = area.y, .width = area.width, .height = 1 }, palette.surface1);
    const chip_height = @min(px.px(26), @max(0, area.height - px.px(8)));
    const y = area.y + @floor((area.height - chip_height) / 2);
    const gap = px.px(8);
    var value_storage: [labels.path_bytes]u8 = undefined;
    const scope_value = self.scopeValue(&value_storage);
    var scope_widths: [scope_chips.len]f32 = undefined;
    var scope_total: f32 = px.px(4);
    const effective = promptScope(history.effective_scope);
    for (scope_chips, 0..) |chip, index| {
        const selected = effective == chip.scope;
        scope_widths[index] = try Chip.width(canvas, chip.text, if (selected) scope_value else "");
        scope_total += scope_widths[index] + px.px(2);
    }
    var author_widths: [author_chips.len]f32 = undefined;
    var author_total: f32 = px.px(4);
    for (author_chips, 0..) |chip, index| {
        author_widths[index] = try Chip.width(canvas, chip.text, "");
        author_total += author_widths[index] + px.px(2);
    }
    const failed_width = try Chip.width(canvas, "Failed", "");
    const scope_key = keyText(.tab);
    const author_key = keyText(.back_tab);
    const key_gap = px.px(8);
    const scope_key_width = try canvas.measure(.{ .text = scope_key }) + key_gap;
    const author_key_width = try canvas.measure(.{ .text = author_key }) + key_gap;
    const failed_key_width = try canvas.measure(.{ .text = "!" }) + key_gap;
    const available = area.width - px.px(24);
    const with_keys = scope_total + scope_key_width + gap + author_total + author_key_width + gap + failed_width + failed_key_width;
    const show_keys = with_keys <= available;
    const show_right = show_keys or scope_total + gap + author_total + gap + failed_width <= available;

    var x = area.x + px.px(12);
    try canvas.fillRoundedAt(.{ .x = x, .y = y, .width = scope_total, .height = chip_height }, .{ .color = palette.surface0, .radius = px.px(6) });
    x += px.px(2);
    for (scope_chips, 0..) |chip, index| {
        const selected = effective == chip.scope;
        try (Chip{
            .bounds = .{ .x = x, .y = y + px.px(2), .width = scope_widths[index], .height = @max(0, chip_height - px.px(4)) },
            .text = chip.text,
            .value = if (selected) scope_value else "",
            .action = .{ .history = .{ .select_scope = chip.scope } },
            .generation = prompt.generation,
            .selected = selected,
        }).draw(canvas);
        x += scope_widths[index] + px.px(2);
    }
    x += px.px(2);
    if (show_keys) {
        x += key_gap;
        x += try canvas.textAt(.{ .x = x, .y = y, .width = scope_key_width, .height = chip_height }, .{ .text = scope_key, .color = palette.overlay1 });
    }
    if (!show_right) {
        return;
    }

    var right = area.x + area.width - px.px(12);
    if (show_keys) {
        right -= failed_key_width;
        _ = try canvas.textAt(.{ .x = right + key_gap, .y = y, .width = failed_key_width, .height = chip_height }, .{ .text = "!", .color = palette.overlay1 });
    }
    right -= failed_width;
    try (Chip{
        .bounds = .{ .x = right, .y = y, .width = failed_width, .height = chip_height },
        .text = "Failed",
        .action = .{ .history = .toggle_failed },
        .generation = prompt.generation,
        .selected = filters.failed_only,
        .danger = true,
    }).draw(canvas);
    right -= gap;
    if (show_keys) {
        right -= author_key_width;
        _ = try canvas.textAt(.{ .x = right + key_gap, .y = y, .width = author_key_width, .height = chip_height }, .{ .text = author_key, .color = palette.overlay1 });
    }
    right -= author_total;
    try canvas.fillRoundedAt(.{ .x = right, .y = y, .width = author_total, .height = chip_height }, .{ .color = palette.surface0, .radius = px.px(6) });
    x = right + px.px(2);
    for (author_chips, 0..) |chip, index| {
        try (Chip{
            .bounds = .{ .x = x, .y = y + px.px(2), .width = author_widths[index], .height = @max(0, chip_height - px.px(4)) },
            .text = chip.text,
            .action = .{ .history = .{ .select_author = chip.author } },
            .generation = prompt.generation,
            .selected = filters.author == chip.author,
        }).draw(canvas);
        x += author_widths[index] + px.px(2);
    }
}

// What the selected scope resolves to: the workspace name or the focused
// pane's directory; global and pane scopes say enough by themselves.
fn scopeValue(self: HistoryModal, storage: *[labels.path_bytes]u8) []const u8 {
    const model = self.projection.model;
    return switch (self.projection.history.effective_scope) {
        .global, .pane => "",
        .workspace => model.workspaceName(),
        .cwd => blk: {
            const active = model.tabs.activeSlot() orelse break :blk "";
            const pane = data.tab_layout.focusedPaneConst(model, active) orelse break :blk "";
            break :blk labels.compactPath(pane.cwdSlice(), storage);
        },
    };
}

// ---------------------------------------------------------------------------
// The field
// ---------------------------------------------------------------------------

fn search(self: HistoryModal, canvas: *Canvas) !void {
    const area = self.layout.search;
    if (area.height <= 0 or area.width <= 0) {
        return;
    }

    const palette = canvas.theme.palette;
    const px = canvas.chrome;
    const prompt = self.projection.prompt.?;
    const history = self.projection.history;
    try canvas.fillAt(.{ .x = area.x, .y = area.y, .width = area.width, .height = 1 }, palette.surface1);
    if (history.phase == .loading and history.has_page) {
        try self.loadingLine(canvas, area);
    }

    const icon_width = px.px(18);
    try canvas.iconAt(.{
        .x = area.x + px.px(16),
        .y = area.y,
        .width = icon_width,
        .height = area.height,
    }, .{ .text = search_glyph, .face = .sans, .size = .body, .color = palette.subtext0 });

    const close_width = @min(px.px(38), area.width / 4);
    const close_height = @min(px.px(22), area.height);
    const close: Rect = .{
        .x = area.x + area.width - px.px(14) - close_width,
        .y = area.y + @floor((area.height - close_height) / 2),
        .width = close_width,
        .height = close_height,
    };
    try (FormButton{
        .bounds = close,
        .text = "esc",
        .label = if (prompt.inspecting()) "Back to history" else "Close history",
        .action = .{ .prompt = .cancel },
        .generation = prompt.generation,
        .namespace = 1,
        .quiet = true,
    }).draw(canvas);
    try canvas.ringAt(close, .{ .color = palette.overlay0, .width = px.px(1), .radius = px.px(4), .alpha = 0.6 });

    const field_x = area.x + px.px(16) + icon_width + px.px(10);
    var field = TextField.fromPrompt(&prompt, .{
        .x = field_x,
        .y = area.y,
        .width = @max(0, close.x - px.px(10) - field_x),
        .height = area.height,
    }, .name);
    field.form_control = true;
    field.bare = true;
    field.label = "Search command history";
    field.placeholder = "Search commands";
    try field.draw(canvas);
}

// An indeterminate 2 px band walks the top of the field while a page is
// on its way; the previous page stays visible behind it.
fn loadingLine(self: HistoryModal, canvas: *Canvas, area: Rect) !void {
    _ = self;
    const px = canvas.chrome;
    const step: u64 = if (canvas.animation) |clock| clock.step(loading_step_ns) % loading_steps else loading_steps / 3;
    const span = area.width / 3;
    const travel = area.width + span;
    const x = area.x - span + travel * @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(loading_steps));
    const first = canvas.quads.items().len;
    try canvas.fillAt(.{ .x = x, .y = area.y, .width = span, .height = px.px(2) }, canvas.theme.palette.accent);
    canvas.quads.clipFrom(first, area);
}

// ---------------------------------------------------------------------------
// The footer
// ---------------------------------------------------------------------------

const HintAction = enum { none, submit, submit_alternate, toggle_inspection, copy, remove, cancel, visit_pane };

/// One footer hint; a hint with an action is also a clickable control, so
/// the pointer reaches everything the keys do without extra buttons.
const Hint = struct {
    key: []const u8,
    word: []const u8,
    action: HintAction = .none,
};

const mac_browse_paste = [_]Hint{
    .{ .key = "↑↓", .word = "select" },
    .{ .key = "↩", .word = "paste", .action = .submit },
    .{ .key = "⇧↩", .word = "run", .action = .submit_alternate },
    .{ .key = "⌃O", .word = "details", .action = .toggle_inspection },
    .{ .key = "⌘C", .word = "copy", .action = .copy },
    .{ .key = "⌘⌫", .word = "delete", .action = .remove },
    .{ .key = "esc", .word = "close", .action = .cancel },
};
const mac_browse_run = [_]Hint{
    .{ .key = "↑↓", .word = "select" },
    .{ .key = "↩", .word = "run", .action = .submit },
    .{ .key = "⇧↩", .word = "paste", .action = .submit_alternate },
    .{ .key = "⌃O", .word = "details", .action = .toggle_inspection },
    .{ .key = "⌘C", .word = "copy", .action = .copy },
    .{ .key = "⌘⌫", .word = "delete", .action = .remove },
    .{ .key = "esc", .word = "close", .action = .cancel },
};
const pc_browse_paste = [_]Hint{
    .{ .key = "↑↓", .word = "select" },
    .{ .key = "Enter", .word = "paste", .action = .submit },
    .{ .key = "Shift+Enter", .word = "run", .action = .submit_alternate },
    .{ .key = "Ctrl+O", .word = "details", .action = .toggle_inspection },
    .{ .key = "Ctrl+C", .word = "copy", .action = .copy },
    .{ .key = "Ctrl+D", .word = "delete", .action = .remove },
    .{ .key = "Esc", .word = "close", .action = .cancel },
};
const pc_browse_run = [_]Hint{
    .{ .key = "↑↓", .word = "select" },
    .{ .key = "Enter", .word = "run", .action = .submit },
    .{ .key = "Shift+Enter", .word = "paste", .action = .submit_alternate },
    .{ .key = "Ctrl+O", .word = "details", .action = .toggle_inspection },
    .{ .key = "Ctrl+C", .word = "copy", .action = .copy },
    .{ .key = "Ctrl+D", .word = "delete", .action = .remove },
    .{ .key = "Esc", .word = "close", .action = .cancel },
};
const mac_inspect_paste = [_]Hint{
    .{ .key = "⌃O", .word = "back", .action = .toggle_inspection },
    .{ .key = "⇞⇟", .word = "scroll" },
    .{ .key = "⌥↩", .word = "go to pane", .action = .visit_pane },
    .{ .key = "↩", .word = "paste", .action = .submit },
    .{ .key = "esc", .word = "back", .action = .cancel },
};
const mac_inspect_run = [_]Hint{
    .{ .key = "⌃O", .word = "back", .action = .toggle_inspection },
    .{ .key = "⇞⇟", .word = "scroll" },
    .{ .key = "⌥↩", .word = "go to pane", .action = .visit_pane },
    .{ .key = "↩", .word = "run", .action = .submit },
    .{ .key = "esc", .word = "back", .action = .cancel },
};
const pc_inspect_paste = [_]Hint{
    .{ .key = "Ctrl+O", .word = "back", .action = .toggle_inspection },
    .{ .key = "PgUp PgDn", .word = "scroll" },
    .{ .key = "Alt+Enter", .word = "go to pane", .action = .visit_pane },
    .{ .key = "Enter", .word = "paste", .action = .submit },
    .{ .key = "Esc", .word = "back", .action = .cancel },
};
const pc_inspect_run = [_]Hint{
    .{ .key = "Ctrl+O", .word = "back", .action = .toggle_inspection },
    .{ .key = "PgUp PgDn", .word = "scroll" },
    .{ .key = "Alt+Enter", .word = "go to pane", .action = .visit_pane },
    .{ .key = "Enter", .word = "run", .action = .submit },
    .{ .key = "Esc", .word = "back", .action = .cancel },
};

// Every table is a constant, so the footer borrows static memory.
fn hints(inspecting: bool, enter_runs: bool) []const Hint {
    const mac = key_label.host_style == .mac;
    if (inspecting) {
        if (mac) {
            return if (enter_runs) &mac_inspect_run else &mac_inspect_paste;
        }

        return if (enter_runs) &pc_inspect_run else &pc_inspect_paste;
    }
    if (mac) {
        return if (enter_runs) &mac_browse_run else &mac_browse_paste;
    }

    return if (enter_runs) &pc_browse_run else &pc_browse_paste;
}

fn footer(self: HistoryModal, canvas: *Canvas) !void {
    const area = self.layout.footer;
    if (area.height <= 0 or area.width <= 0) {
        return;
    }

    const palette = canvas.theme.palette;
    const px = canvas.chrome;
    const prompt = self.projection.prompt.?;
    const history = self.projection.history;
    try canvas.fillAt(.{ .x = area.x, .y = area.y, .width = area.width, .height = 1 }, palette.surface1);
    const left = area.x + px.px(16);
    const limit = area.x + area.width - px.px(16);
    if (history.errorSlice().len != 0) {
        try (Caption{
            .bounds = .{ .x = left, .y = area.y, .width = @max(0, limit - left), .height = area.height },
            .label = .{ .text = history.errorSlice(), .face = .sans, .size = .small, .color = palette.red },
        }).draw(canvas);
        return;
    }

    var x = left;
    for (hints(prompt.inspecting(), history.enter_runs)) |hint| {
        const key: Label = .{ .text = hint.key, .color = palette.text, .alpha = 0.85 };
        const word: Label = .{ .text = hint.word, .face = .sans, .size = .small, .color = palette.subtext0 };
        const key_width = try canvas.measure(key);
        const word_width = try canvas.measure(word);
        if (x + key_width + px.px(6) + word_width > limit) {
            break;
        }

        try self.hintControl(canvas, hint, .{
            .x = x - px.px(6),
            .y = area.y + px.px(5),
            .width = key_width + px.px(6) + word_width + px.px(12),
            .height = @max(0, area.height - px.px(10)),
        });
        _ = try canvas.textAt(.{ .x = x, .y = area.y, .width = key_width, .height = area.height }, key);
        x += key_width + px.px(6);
        _ = try canvas.textAt(.{ .x = x, .y = area.y, .width = word_width, .height = area.height }, word);
        x += word_width + px.px(16);
    }

    if (history.len == 0) {
        return;
    }

    var storage: [64]u8 = undefined;
    const range = std.fmt.bufPrint(&storage, "{d}–{d}{s}{s}", .{
        @as(u64, history.page_offset) + 1,
        @as(u64, history.page_offset) + history.len,
        if (history.has_more) (if (key_label.host_style == .mac) "  ·  ⇞ older" else "  ·  PgUp older") else "",
        if (history.match_fuzzy and self.queryFilters().query.len != 0) "  ·  fuzzy" else "",
    }) catch "";
    const label: Label = .{ .text = range, .face = .sans, .size = .small, .color = palette.subtext0 };
    const width = try canvas.measure(label);
    if (x + width <= limit) {
        _ = try canvas.textAt(.{ .x = limit - width, .y = area.y, .width = width, .height = area.height }, label);
    }
}

// A hint with an action registers the same control its key triggers and
// lights up under the pointer; the delivered page revision guards submits.
fn hintControl(self: HistoryModal, canvas: *Canvas, hint: Hint, bounds: Rect) !void {
    const prompt = self.projection.prompt.?;
    const history = self.projection.history;
    const ready = history.phase == .ready and history.len != 0;
    const selected: u16 = if (history.len == 0) 0 else @min(prompt.selection(), history.len - 1);
    const choice: HistoryChoice = .{ .index = selected, .revision = history.version() };
    const action: Target.Action = switch (hint.action) {
        .none => return,
        .submit => .{ .history = .{ .submit = choice } },
        .submit_alternate => .{ .history = .{ .submit_alternate = choice } },
        .toggle_inspection => .{ .history = .toggle_inspection },
        .copy => .{ .history = .copy },
        .remove => .{ .history = .remove },
        .cancel => .{ .prompt = .cancel },
        .visit_pane => .{ .history = .visit_pane },
    };
    const enabled = switch (hint.action) {
        .cancel => true,
        .toggle_inspection => ready,
        else => ready,
    };
    var hovered = false;
    if (canvas.widgets) |state| {
        const target = (Target{
            .id = .{ .generation = prompt.generation },
            .namespace = 5,
            .bounds = bounds,
            .action = action,
            .layer = 1,
            .focusable = false,
            .enabled = enabled,
        }).labelled(hint.word);
        const id = try state.dispatcher.add(target);
        hovered = if (state.dispatcher.hovered) |hover| hover.eql(id) else false;
    }

    if (hovered and enabled) {
        try canvas.fillRoundedAt(bounds, .{ .color = canvas.theme.palette.surface0, .radius = canvas.chrome.px(4) });
    }
}

// ---------------------------------------------------------------------------
// The inspector
// ---------------------------------------------------------------------------

fn inspect(self: HistoryModal, canvas: *Canvas) !void {
    const layout = self.layout;
    const metrics = Metrics.fromCanvas(canvas);
    if (layout.inspection.width <= 0 or layout.inspection.height <= 0) {
        return;
    }

    const palette = canvas.theme.palette;
    if (layout.results.width > 0) {
        try canvas.fillAt(.{ .x = layout.inspection.x, .y = layout.inspection.y, .width = 1, .height = layout.inspection.height }, palette.surface1);
    }

    const content = layout.inspectionContent(metrics);
    const columns = columnsFor(content, metrics);
    const row_height: f32 = @floatFromInt(metrics.terminal.cell_height);
    if (columns == 0 or row_height <= 0) {
        return;
    }

    const prompt = self.projection.prompt.?;
    const history = self.projection.history;
    const selection = @min(prompt.selection(), history.len - 1);
    const details = HistoryDetails.init(self.projection, selection);
    const first = canvas.quads.items().len;
    var lines = details.lines(columns);
    var skip = prompt.detailScroll();
    var row: u16 = 0;
    const rows_count: u16 = @intFromFloat(@floor(content.height / row_height));
    while (lines.next()) |line| {
        if (skip != 0) {
            skip -= 1;
            continue;
        }
        if (row == rows_count) {
            break;
        }

        const area: Rect = .{ .x = content.x, .y = content.y + @as(f32, @floatFromInt(row)) * row_height, .width = content.width, .height = row_height };
        try paintLine(canvas, area, line);
        row += 1;
    }

    canvas.quads.clipFrom(first, content);
    try self.actions(canvas, layout.inspectionActions(metrics), details.pane_open);
}

fn paintLine(canvas: *Canvas, area: Rect, line: HistoryLine) !void {
    const palette = canvas.theme.palette;
    const px = canvas.chrome;
    const color: cellgrid.Color = switch (line.tone) {
        .text => palette.text,
        .muted => palette.subtext0,
        .red => palette.red,
        .green => palette.green,
        .teal => palette.teal,
        .yellow => palette.yellow,
    };
    switch (line.kind) {
        .blank => {},
        .command => {
            try canvas.fillAt(area, palette.surface0);
            _ = try canvas.textAt(.{ .x = area.x + px.px(8), .y = area.y, .width = @max(0, area.width - px.px(16)), .height = area.height }, .{ .text = line.text, .color = color });
        },
        .fact => {
            const label_width = @min(px.px(64), area.width / 3);
            _ = try canvas.textAt(.{ .x = area.x, .y = area.y, .width = label_width, .height = area.height }, .{ .text = line.label, .face = .sans, .size = .small, .color = palette.subtext0 });
            const value: Rect = .{ .x = area.x + label_width, .y = area.y, .width = @max(0, area.width - label_width), .height = area.height };
            if (line.mono) {
                _ = try canvas.textAt(value, .{ .text = line.text, .color = color });
            } else {
                _ = try canvas.textAt(value, .{ .text = line.text, .face = .sans, .size = .body, .color = color });
            }
        },
        .heading => _ = try canvas.textAt(area, .{ .text = line.text, .face = .sans, .size = .small, .bold = true, .color = palette.subtext0 }),
        .output => _ = try canvas.textAt(area, .{ .text = line.text, .color = color }),
    }
}

fn actions(self: HistoryModal, canvas: *Canvas, area: Rect, pane_open: bool) !void {
    if (area.height <= 0 or area.width <= 0) {
        return;
    }

    const px = canvas.chrome;
    const prompt = self.projection.prompt.?;
    const history = self.projection.history;
    const palette = canvas.theme.palette;
    const selected = @min(prompt.selection(), history.len - 1);
    const revision = history.version();
    const ready = history.phase == .ready;
    const primary_text = if (history.enter_runs) "Run" else "Paste";
    const secondary_text = if (history.enter_runs) "Paste" else "Run";
    const buttons = [_]FormButton{
        .{ .bounds = area, .text = primary_text, .action = .{ .history = .{ .submit = .{ .index = selected, .revision = revision } } }, .generation = prompt.generation, .namespace = 0, .primary = true, .enabled = ready },
        .{ .bounds = area, .text = secondary_text, .action = .{ .history = .{ .submit_alternate = .{ .index = selected, .revision = revision } } }, .generation = prompt.generation, .namespace = 0, .enabled = ready },
        .{ .bounds = area, .text = "Copy", .action = .{ .history = .copy }, .generation = prompt.generation, .namespace = 0, .enabled = ready },
        .{ .bounds = area, .text = "Delete", .action = .{ .history = .remove }, .generation = prompt.generation, .namespace = 0, .enabled = ready, .label_color = palette.red },
        .{ .bounds = area, .text = "Go to pane", .action = .{ .history = .visit_pane }, .generation = prompt.generation, .namespace = 0, .enabled = ready and pane_open },
    };
    var x = area.x;
    for (buttons) |template| {
        if (!template.enabled and template.action.history == .visit_pane) {
            continue;
        }

        var button = template;
        const width = try canvas.measure(.{ .text = button.text, .face = .sans, .size = .body, .bold = button.primary }) + px.px(24);
        if (x + width > area.x + area.width) {
            break;
        }

        button.bounds = .{ .x = x, .y = area.y, .width = width, .height = area.height };
        try button.draw(canvas);
        x += width + px.px(8);
    }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn queryFilters(self: HistoryModal) client.HistoryFilters {
    const prompt = &self.projection.prompt.?;
    return client.history_palette.historyFilters(prompt, prompt.field.text());
}

// The wire and the prompt number their scopes differently.
fn promptScope(scope: core.HistoryScope) data.PromptHistoryScope {
    return switch (scope) {
        .global => .global,
        .workspace => .workspace,
        .cwd => .cwd,
        .pane => .pane,
    };
}

fn keyText(code: KeyName) []const u8 {
    const mac = key_label.host_style == .mac;
    return switch (code) {
        .tab => if (mac) "⇥" else "Tab",
        .back_tab => if (mac) "⇧⇥" else "Shift+Tab",
        .page_up => if (mac) "⇞" else "PgUp",
    };
}

const KeyName = enum { tab, back_tab, page_up };

fn columnsFor(content: Rect, metrics: Metrics) u16 {
    return @intFromFloat(@min(65535, @floor(content.width / @as(f32, @floatFromInt(@max(1, metrics.terminal.cell_width))))));
}
