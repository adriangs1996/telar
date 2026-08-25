//! Task and agent activity sidebar.
//!
//! Cells own text, editing, cursor placement, hover, and every hit target.
//! `Semantic` describes only reusable graphical decoration for the optional
//! KGP renderer. The same actions remain available when graphics disappear.

const std = @import("std");
const edit = @import("../edit.zig");
const term = @import("../term.zig");
const widget = @import("context.zig");
const model = @import("sidebar_model.zig");
const ui = @import("../ui.zig");

pub const Snapshot = model.Snapshot;
pub const SnapshotInput = model.SnapshotInput;
pub const TaskInput = model.TaskInput;
pub const TaskKey = model.TaskKey;
pub const Tab = model.Tab;
pub const Section = model.Section;
pub const TaskAction = model.TaskAction;
pub const Origin = model.Origin;
pub const Provider = model.Provider;
pub const Status = model.Status;

pub const max_controls = model.max_tasks + 2;
pub const max_provider_marks = model.max_tasks;
const max_rows = model.max_tasks * 4 + model.section_count;

pub const State = struct {
    selected_tab: Tab = .inbox,
    selected_task: ?TaskKey = null,
    scope_open: bool = false,
    search_active: bool = false,
    search: edit.Field(256) = .init(""),
    scroll: u16 = 0,
    total_rows: u16 = 0,

    pub fn capturesKeyboard(state: *const State) bool {
        return state.search_active;
    }

    pub fn handleKey(state: *State, key: term.Event.Key) bool {
        if (!state.search_active) return false;
        const extend = key.mods.shift;

        if (key.isCtrl('a')) {
            state.search.selectAll();
            return true;
        }
        if (key.isCtrl('u')) {
            state.search.setText("");
            return true;
        }
        switch (key.code) {
            .char => |char| if (!key.mods.ctrl and !key.mods.alt)
                state.search.insert(char.slice()),
            .backspace => state.search.backspace(),
            .delete => state.search.delete(),
            .left => if (key.mods.ctrl or key.mods.alt)
                state.search.moveWordLeft(extend)
            else
                state.search.moveLeft(extend),
            .right => if (key.mods.ctrl or key.mods.alt)
                state.search.moveWordRight(extend)
            else
                state.search.moveRight(extend),
            .home => state.search.home(extend),
            .end => state.search.end(extend),
            .escape => {
                if (state.search.text().len != 0)
                    state.search.setText("")
                else
                    state.search_active = false;
            },
            .enter, .down, .tab, .back_tab => state.search_active = false,
            else => {},
        }
        state.scroll = 0;
        return true;
    }

    pub fn paste(state: *State, bytes: []const u8) bool {
        if (!state.search_active) return false;
        var start: usize = 0;
        for (bytes, 0..) |byte, index| {
            if (byte != '\r' and byte != '\n' and byte != '\t') continue;
            state.search.insert(bytes[start..index]);
            state.search.insert(" ");
            start = index + 1;
        }
        state.search.insert(bytes[start..]);
        state.scroll = 0;
        return true;
    }

    pub fn scrollBy(state: *State, rows: i16, viewport_height: u16) bool {
        const max_scroll = state.total_rows -| viewport_height;
        const before = state.scroll;
        if (rows < 0) {
            state.scroll -|= @intCast(-rows);
        } else {
            state.scroll = @min(max_scroll, state.scroll +| @as(u16, @intCast(rows)));
        }
        return before != state.scroll;
    }
};

pub const Semantic = struct {
    area: ui.Rect,
    selected_card: ?ui.Rect = null,
    provider_marks: [max_provider_marks]ProviderMark = undefined,
    provider_mark_count: u8 = 0,
    controls: [max_controls]Control = undefined,
    control_count: u8 = 0,
    list_area: ui.Rect = .{},
    cursor: ?widget.Cursor = null,

    pub const ProviderMark = struct {
        area: ui.Rect,
        provider: Provider,
    };

    pub const Control = struct {
        area: ui.Rect,
        kind: Kind,

        pub const Kind = enum { neutral, primary };
    };

    fn addProviderMark(semantic: *Semantic, mark: ProviderMark) void {
        if (semantic.provider_mark_count == semantic.provider_marks.len) return;
        semantic.provider_marks[semantic.provider_mark_count] = mark;
        semantic.provider_mark_count += 1;
    }

    fn addControl(semantic: *Semantic, control: Control) void {
        if (semantic.control_count == semantic.controls.len) return;
        semantic.controls[semantic.control_count] = control;
        semantic.control_count += 1;
    }
};

pub const Input = struct {
    area: ui.Rect,
    snapshot: *const Snapshot,
    state: *State,
    transparent: bool,
};

const Row = union(enum) {
    section: Section,
    task: struct { index: u8, line: u2 },
    blank,
};

pub fn render(context: *widget.Context, input: Input) Semantic {
    var semantic: Semantic = .{ .area = input.area };
    renderCells(context, input, &semantic);
    return semantic;
}

fn renderCells(context: *widget.Context, input: Input, semantic: *Semantic) void {
    const area = input.area;
    if (area.isEmpty()) return;
    const background = cellBackground(context, input.transparent);
    const faint: ui.Style = .{ .fg = context.palette.overlay0, .bg = background };
    context.buffer.fill(area, " ", .{ .fg = context.palette.text, .bg = background });
    context.buffer.box(area, faint, null);
    if (area.w > 8) _ = context.buffer.writeText(area, area.x + 2, area.y, " telar ", .{
        .fg = context.palette.subtext0,
        .bg = background,
        .flags = .{ .bold = true },
    });
    if (area.w < 30 or area.h < 14) return;

    const inside: ui.Rect = .{
        .x = area.x + 1,
        .y = area.y + 1,
        .w = area.w - 2,
        .h = area.h - 2,
    };
    var y = inside.y;
    y = drawSearch(context, input, semantic, inside, y);
    y = drawRule(context, area, y, background);
    y = drawTabs(context, input, inside, y, background);
    y = drawRule(context, area, y, background);
    y = drawScope(context, input, inside, y, background);
    y = drawRule(context, area, y, background);

    const footer_y = area.y + area.h - 2;
    const footer_rule_y = footer_y - 1;
    if (footer_rule_y > y) {
        semantic.list_area = .{
            .x = inside.x,
            .y = y,
            .w = inside.w,
            .h = footer_rule_y - y,
        };
        drawList(context, input, semantic);
        _ = drawRule(context, area, footer_rule_y, background);
    }
    drawFooter(context, inside, footer_y, background);
}

fn drawSearch(
    context: *widget.Context,
    input: Input,
    semantic: *Semantic,
    area: ui.Rect,
    y: u16,
) u16 {
    const background = cellBackground(context, input.transparent);
    const row: ui.Rect = .{ .x = area.x, .y = y, .w = area.w, .h = 1 };
    const focused = input.state.search_active;
    const row_bg = if (focused and !input.transparent) context.palette.surface0 else background;
    context.buffer.fill(row, " ", .{ .bg = row_bg });

    var right = row.x + row.w - 1;
    right -= drawTopControl(context, semantic, row, right, "+", .sidebar_new_task, input.transparent);
    right -= drawTopControl(context, semantic, row, right, "ctrl+k", .sidebar_command_palette, input.transparent);

    var x = row.x + 1;
    x += context.buffer.writeText(row, x, y, "/", .{
        .fg = context.palette.accent,
        .bg = row_bg,
        .flags = .{ .bold = true },
    });
    x += context.buffer.writeText(row, x, y, " ", .{ .bg = row_bg });
    const field_width = right -| x;
    context.hits.add(.{ .x = row.x, .y = y, .w = right -| row.x, .h = 1 }, .sidebar_focus_search);

    if (input.state.search.text().len == 0 and !focused) {
        _ = context.buffer.writeTruncated(row, x, y, "search tasks\u{2026}", field_width, .{
            .fg = context.palette.overlay0,
            .bg = row_bg,
        });
        return y + 1;
    }

    const shown = input.state.search.view(field_width);
    _ = context.buffer.writeText(row, x, y, shown.text, .{
        .fg = context.palette.text,
        .bg = row_bg,
    });
    if (shown.selection) |selection| {
        var column = x + selection[0];
        while (column < x + selection[1] and column < right) : (column += 1) {
            if (context.buffer.at(column, y)) |cell| cell.style.flags.inverse = true;
        }
    }
    if (shown.clipped_left) _ = context.buffer.writeText(row, x, y, "\u{2039}", .{
        .fg = context.palette.overlay0,
        .bg = row_bg,
    });
    if (shown.clipped_right and right > x) _ = context.buffer.writeText(row, right - 1, y, "\u{203a}", .{
        .fg = context.palette.overlay0,
        .bg = row_bg,
    });
    if (focused) semantic.cursor = .{ .cursor_x = x + shown.cursor, .cursor_y = y };
    return y + 1;
}

fn drawTopControl(
    context: *widget.Context,
    semantic: *Semantic,
    area: ui.Rect,
    right: u16,
    label: []const u8,
    action: widget.Action,
    transparent: bool,
) u16 {
    const width = ui.measure(label) + 2;
    if (right < area.x + width) return 0;
    const x = right - width;
    const rect: ui.Rect = .{ .x = x, .y = area.y, .w = width, .h = 1 };
    const hovered = context.isHovered(action);
    const background = if (hovered)
        context.palette.surface1
    else if (transparent)
        ui.Color.default
    else
        context.palette.surface0;
    context.buffer.fill(rect, " ", .{ .bg = background });
    if (!transparent) {
        _ = context.buffer.writeText(rect, x, area.y, "[", .{ .fg = context.palette.overlay0, .bg = background });
        _ = context.buffer.writeText(rect, x + width - 1, area.y, "]", .{ .fg = context.palette.overlay0, .bg = background });
    }
    _ = context.buffer.writeText(rect, x + 1, area.y, label, .{
        .fg = if (std.mem.eql(u8, label, "+")) context.palette.subtext0 else context.palette.overlay1,
        .bg = background,
        .flags = .{ .bold = hovered },
    });
    context.hits.add(rect, action);
    semantic.addControl(.{ .area = rect, .kind = .neutral });
    return width + 1;
}

fn drawTabs(
    context: *widget.Context,
    input: Input,
    area: ui.Rect,
    y: u16,
    background: ui.Color,
) u16 {
    const row: ui.Rect = .{ .x = area.x, .y = y, .w = area.w, .h = 1 };
    const underline: ui.Rect = .{ .x = area.x, .y = y + 1, .w = area.w, .h = 1 };
    context.buffer.fill(row, " ", .{ .bg = background });
    context.buffer.fill(underline, " ", .{ .bg = background });

    var x = row.x + 1;
    const gap: u16 = if (area.w >= 50) 2 else 1;
    for ([_]Tab{ .inbox, .tasks, .reviews }) |tab| {
        const active = input.state.selected_tab == tab;
        const action: widget.Action = .{ .sidebar_select_tab = tab };
        const hovered = context.isHovered(action);
        const color = if (active) context.palette.text else if (hovered) context.palette.subtext0 else context.palette.overlay0;
        const start = x;
        var shortcut: [3]u8 = .{ '[', tab.shortcut(), ']' };
        x += context.buffer.writeText(row, x, y, &shortcut, .{
            .fg = color,
            .bg = background,
            .flags = .{ .bold = active },
        });
        x += context.buffer.writeText(row, x, y, " ", .{ .bg = background });
        x += context.buffer.writeText(row, x, y, tab.label(), .{
            .fg = color,
            .bg = background,
            .flags = .{ .bold = active },
        });
        x += context.buffer.writeText(row, x, y, " ", .{ .bg = background });
        var count_buffer: [8]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buffer, "{d}", .{input.snapshot.tabCount(tab)}) catch "";
        x += context.buffer.writeText(row, x, y, count, .{
            .fg = if (active) context.palette.accent else context.palette.overlay0,
            .bg = background,
        });
        if (active) {
            var underline_x = start;
            while (underline_x < x) : (underline_x += 1) _ = context.buffer.writeText(
                underline,
                underline_x,
                y + 1,
                "\u{2501}",
                .{ .fg = context.palette.accent, .bg = background },
            );
        }
        context.hits.add(.{ .x = start, .y = y, .w = x - start, .h = 2 }, action);
        x += gap;
        if (x >= row.x + row.w) break;
    }
    return y + 2;
}

fn drawScope(
    context: *widget.Context,
    input: Input,
    area: ui.Rect,
    y: u16,
    background: ui.Color,
) u16 {
    const row: ui.Rect = .{ .x = area.x, .y = y, .w = area.w, .h = 1 };
    const hovered = context.isHovered(.sidebar_toggle_scope);
    const row_bg = if (hovered) context.palette.surface1 else background;
    context.buffer.fill(row, " ", .{ .bg = row_bg });

    var count_buffer: [24]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buffer, "{d} tasks", .{input.snapshot.tabCount(input.state.selected_tab)}) catch "";
    const count_width = ui.measure(count);
    const left_width = row.w -| count_width -| 3;
    var x = row.x + 1;
    x += context.buffer.writeText(row, x, y, if (input.state.scope_open) "\u{25b4}" else "\u{25be}", .{
        .fg = context.palette.overlay0,
        .bg = row_bg,
    });
    x += context.buffer.writeText(row, x, y, " ", .{ .bg = row_bg });
    _ = context.buffer.writeTruncated(row, x, y, "all scopes", left_width -| 2, .{
        .fg = context.palette.subtext0,
        .bg = row_bg,
    });
    _ = context.buffer.writeRight(.{ .x = row.x, .y = y, .w = row.w - 1, .h = 1 }, y, count, .{
        .fg = context.palette.overlay0,
        .bg = row_bg,
    });
    context.hits.add(row, .sidebar_toggle_scope);
    return y + 1;
}

fn drawList(context: *widget.Context, input: Input, semantic: *Semantic) void {
    const area = semantic.list_area;
    const background = cellBackground(context, input.transparent);
    context.buffer.fill(area, " ", .{ .bg = background });

    var rows: [max_rows]Row = undefined;
    var section_counts: [model.section_count]u16 = @splat(0);
    const total = buildRows(input.snapshot, input.state, &rows, &section_counts);
    input.state.total_rows = total;
    const max_scroll = total -| area.h;
    input.state.scroll = @min(input.state.scroll, max_scroll);

    if (total == 0) {
        drawEmpty(context, area, background, input.state.search.text().len != 0);
        return;
    }

    const content: ui.Rect = .{ .x = area.x, .y = area.y, .w = area.w -| 1, .h = area.h };
    var line: u16 = 0;
    while (line < area.h) : (line += 1) {
        const row_index = input.state.scroll + line;
        if (row_index >= total) break;
        const y = area.y + line;
        switch (rows[row_index]) {
            .blank => {},
            .section => |section| drawSection(
                context,
                content,
                y,
                section,
                section_counts[@intFromEnum(section)],
                background,
            ),
            .task => |task_row| drawTaskLine(
                context,
                input,
                semantic,
                content,
                y,
                task_row.index,
                task_row.line,
                background,
            ),
        }
    }
    drawScrollbar(context, input.state, area, total, background);
}

fn buildRows(
    snapshot: *const Snapshot,
    state: *const State,
    rows: []Row,
    section_counts: *[model.section_count]u16,
) u16 {
    var len: usize = 0;
    for ([_]Section{ .needs_you, .ready, .running, .background }) |section| {
        var seen = false;
        for (snapshot.slice(), 0..) |*task, index| {
            if (task.section != section or !taskVisible(task, state)) continue;
            section_counts[@intFromEnum(section)] += 1;
            if (!seen) {
                rows[len] = .{ .section = section };
                len += 1;
                seen = true;
            }
            rows[len] = .{ .task = .{ .index = @intCast(index), .line = 0 } };
            rows[len + 1] = .{ .task = .{ .index = @intCast(index), .line = 1 } };
            rows[len + 2] = .{ .task = .{ .index = @intCast(index), .line = 2 } };
            rows[len + 3] = .blank;
            len += 4;
        }
    }
    return @intCast(len);
}

fn taskVisible(task: *const model.Task, state: *const State) bool {
    if (!model.visibleInTab(task, state.selected_tab)) return false;
    const query = state.search.text();
    if (query.len == 0) return true;
    return containsIgnoreCase(task.title.slice(), query) or
        containsIgnoreCase(task.place.slice(), query) or
        containsIgnoreCase(task.place_detail.slice(), query) or
        containsIgnoreCase(task.tool.slice(), query) or
        containsIgnoreCase(task.note.slice(), query);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var equal = true;
        for (needle, 0..) |byte, index| {
            if (std.ascii.toLower(haystack[start + index]) != std.ascii.toLower(byte)) {
                equal = false;
                break;
            }
        }
        if (equal) return true;
    }
    return false;
}

fn drawEmpty(context: *widget.Context, area: ui.Rect, background: ui.Color, filtered: bool) void {
    if (area.h < 2) return;
    const title = if (filtered) "No matching tasks" else "No agent activity yet";
    const detail = if (filtered) "Change or clear the search." else "Detected work will appear here.";
    _ = context.buffer.writeTruncated(area, area.x + 2, area.y + 1, title, area.w -| 4, .{
        .fg = context.palette.subtext0,
        .bg = background,
        .flags = .{ .bold = true },
    });
    if (area.h >= 4) _ = context.buffer.writeTruncated(area, area.x + 2, area.y + 3, detail, area.w -| 4, .{
        .fg = context.palette.overlay0,
        .bg = background,
    });
}

fn drawSection(
    context: *widget.Context,
    area: ui.Rect,
    y: u16,
    section: Section,
    count: u16,
    background: ui.Color,
) void {
    const row: ui.Rect = .{ .x = area.x, .y = y, .w = area.w, .h = 1 };
    const color = sectionColor(context, section);
    var x = row.x + 1;
    x += context.buffer.writeText(row, x, y, section.label(), .{
        .fg = color,
        .bg = background,
        .flags = .{ .bold = true },
    });
    x += 1;
    var count_buffer: [8]u8 = undefined;
    const count_text = std.fmt.bufPrint(&count_buffer, "{d}", .{count}) catch "";
    const rule_end = row.x + row.w -| ui.measure(count_text) -| 2;
    while (x < rule_end) : (x += 1) _ = context.buffer.writeText(row, x, y, "\u{2500}", .{
        .fg = context.palette.surface1,
        .bg = background,
    });
    _ = context.buffer.writeRight(.{ .x = row.x, .y = y, .w = row.w -| 1, .h = 1 }, y, count_text, .{
        .fg = context.palette.overlay0,
        .bg = background,
    });
}

fn drawTaskLine(
    context: *widget.Context,
    input: Input,
    semantic: *Semantic,
    area: ui.Rect,
    y: u16,
    task_index: u8,
    line: u2,
    background: ui.Color,
) void {
    const task = &input.snapshot.slice()[task_index];
    const select_action: widget.Action = .{ .sidebar_select_task = task.key };
    const run_action: widget.Action = .{ .sidebar_run_task_action = task.key };
    const selected = if (input.state.selected_task) |key| std.meta.eql(key, task.key) else false;
    const hovered = context.isHovered(select_action) or context.isHovered(run_action);
    const row_bg = if (selected)
        if (input.transparent) ui.Color.default else context.palette.surface0
    else if (hovered)
        context.palette.surface1
    else
        background;
    const row: ui.Rect = .{ .x = area.x, .y = y, .w = area.w, .h = 1 };
    context.buffer.fill(row, " ", .{ .bg = row_bg });

    if (selected) {
        _ = context.buffer.writeText(row, row.x, y, "\u{2503}", .{
            .fg = context.palette.accent,
            .bg = row_bg,
        });
        if (line == 0 and y + 2 < semantic.list_area.y + semantic.list_area.h) {
            semantic.selected_card = .{ .x = row.x, .y = y, .w = row.w, .h = 3 };
        }
    }

    const body: ui.Rect = .{ .x = row.x + 2, .y = y, .w = row.w -| 3, .h = 1 };
    if (body.w == 0) return;
    switch (line) {
        0 => drawTaskTitle(context, input, semantic, body, task, row_bg, run_action),
        1 => drawTaskPlace(context, body, task, row_bg),
        2 => drawTaskOrigin(context, input, semantic, body, task, row_bg),
        else => unreachable,
    }
    context.hits.add(row, select_action);
    if (line == 0 and task.action != .none) {
        const width = taskActionWidth(task.action);
        if (width <= body.w) context.hits.add(.{
            .x = body.x + body.w - width,
            .y = y,
            .w = width,
            .h = 1,
        }, run_action);
    }
}

fn drawTaskTitle(
    context: *widget.Context,
    input: Input,
    semantic: *Semantic,
    area: ui.Rect,
    task: *const model.Task,
    background: ui.Color,
    action: widget.Action,
) void {
    const action_width = if (task.action == .none) 0 else drawTaskAction(
        context,
        input,
        semantic,
        area,
        task.action,
        action,
        background,
    );
    _ = context.buffer.writeTruncated(area, area.x, area.y, task.title.slice(), area.w -| action_width -| 1, .{
        .fg = context.palette.text,
        .bg = background,
        .flags = .{ .bold = true },
    });
}

fn drawTaskAction(
    context: *widget.Context,
    input: Input,
    semantic: *Semantic,
    area: ui.Rect,
    task_action: TaskAction,
    action: widget.Action,
    row_background: ui.Color,
) u16 {
    const width = taskActionWidth(task_action);
    if (width > area.w) return 0;
    const x = area.x + area.w - width;
    const rect: ui.Rect = .{ .x = x, .y = area.y, .w = width, .h = 1 };
    const hovered = context.isHovered(action);
    const filled = task_action.filled();
    const background = if (hovered)
        context.palette.surface1
    else if (filled and input.transparent)
        ui.Color.default
    else if (filled)
        context.palette.accent
    else
        row_background;
    const foreground = if (filled and !hovered)
        context.palette.panel_bg
    else
        taskActionColor(context, task_action);
    context.buffer.fill(rect, " ", .{ .bg = background });
    var cursor = x + 1;
    cursor += context.buffer.writeText(rect, cursor, area.y, task_action.glyph(), .{
        .fg = foreground,
        .bg = background,
    });
    cursor += context.buffer.writeText(rect, cursor, area.y, " ", .{ .bg = background });
    _ = context.buffer.writeText(rect, cursor, area.y, task_action.label(), .{
        .fg = foreground,
        .bg = background,
        .flags = .{ .bold = filled or hovered },
    });
    if (filled) semantic.addControl(.{ .area = rect, .kind = .primary });
    return width;
}

fn taskActionWidth(action: TaskAction) u16 {
    return ui.measure(action.glyph()) + ui.measure(action.label()) + 3;
}

fn drawTaskPlace(context: *widget.Context, area: ui.Rect, task: *const model.Task, background: ui.Color) void {
    var x = area.x;
    x += context.buffer.writeText(area, x, area.y, if (task.origin == .host) "\u{2302}" else "\u{2387}", .{
        .fg = context.palette.overlay0,
        .bg = background,
    });
    x += context.buffer.writeText(area, x, area.y, " ", .{ .bg = background });

    const status_width = statusWidth(task);
    const available = area.x + area.w -| x -| status_width -| 1;
    x += context.buffer.writeTruncated(area, x, area.y, task.place.slice(), available, .{
        .fg = context.palette.subtext0,
        .bg = background,
    });
    if (task.place_detail.slice().len != 0 and x + 3 < area.x + area.w -| status_width) {
        x += context.buffer.writeText(area, x, area.y, " \u{00b7} ", .{
            .fg = context.palette.overlay0,
            .bg = background,
        });
        _ = context.buffer.writeTruncated(
            area,
            x,
            area.y,
            task.place_detail.slice(),
            area.x + area.w -| x -| status_width -| 1,
            .{ .fg = context.palette.subtext0, .bg = background },
        );
    }
    drawStatus(context, area, task, background);
}

fn statusWidth(task: *const model.Task) u16 {
    const detail_width: u16 = if (task.status_detail.slice().len == 0) 0 else ui.measure(task.status_detail.slice()) + 3;
    return ui.measure(task.status.label()) + detail_width + @as(u16, if (task.status == .working) 2 else 0) + 1;
}

fn drawStatus(context: *widget.Context, area: ui.Rect, task: *const model.Task, background: ui.Color) void {
    const width = statusWidth(task);
    if (width > area.w) return;
    const color = statusColor(context, task.status);
    var x = area.x + area.w - width;
    if (task.status == .working) x += context.buffer.writeText(area, x, area.y, "\u{2237} ", .{
        .fg = color,
        .bg = background,
    });
    x += context.buffer.writeText(area, x, area.y, task.status.label(), .{
        .fg = color,
        .bg = background,
        .flags = .{ .bold = true },
    });
    if (task.status_detail.slice().len != 0) {
        x += context.buffer.writeText(area, x, area.y, " \u{00b7} ", .{
            .fg = context.palette.overlay0,
            .bg = background,
        });
        _ = context.buffer.writeText(area, x, area.y, task.status_detail.slice(), .{
            .fg = if (task.status == .failed) context.palette.red else context.palette.subtext0,
            .bg = background,
        });
    }
}

fn drawTaskOrigin(
    context: *widget.Context,
    input: Input,
    semantic: *Semantic,
    area: ui.Rect,
    task: *const model.Task,
    background: ui.Color,
) void {
    const agent = task.origin == .agent;
    const mark_area: ui.Rect = .{ .x = area.x, .y = area.y, .w = 1, .h = 1 };
    if (task.provider == .claude and input.transparent) {
        semantic.addProviderMark(.{ .area = mark_area, .provider = .claude });
    } else {
        _ = context.buffer.writeText(area, area.x, area.y, if (agent) "\u{2733}" else "$", .{
            .fg = if (agent) context.palette.accent else context.palette.subtext0,
            .bg = background,
        });
    }
    var x = area.x + 2;
    x += context.buffer.writeTruncated(area, x, area.y, task.tool.slice(), area.w -| 2, .{
        .fg = if (agent) context.palette.accent else context.palette.subtext0,
        .bg = background,
    });
    if (task.note.slice().len != 0 and x + 3 < area.x + area.w) {
        x += context.buffer.writeText(area, x, area.y, " \u{00b7} ", .{
            .fg = context.palette.overlay0,
            .bg = background,
        });
        _ = context.buffer.writeTruncated(area, x, area.y, task.note.slice(), area.x + area.w -| x, .{
            .fg = context.palette.overlay0,
            .bg = background,
        });
    }
}

fn drawScrollbar(
    context: *widget.Context,
    state: *State,
    list: ui.Rect,
    total: u16,
    background: ui.Color,
) void {
    if (total <= list.h or list.h == 0) return;
    const area: ui.Rect = .{ .x = list.x + list.w - 1, .y = list.y, .w = 1, .h = list.h };
    const thumb = @max(1, area.h * area.h / total);
    const travel = area.h - thumb;
    const max_scroll = total - area.h;
    const offset: u16 = @intCast(@as(u32, state.scroll) * travel / max_scroll);
    var line: u16 = 0;
    while (line < area.h) : (line += 1) {
        const on_thumb = line >= offset and line < offset + thumb;
        _ = context.buffer.writeText(area, area.x, area.y + line, if (on_thumb) "\u{2588}" else "\u{2502}", .{
            .fg = if (on_thumb) context.palette.overlay1 else context.palette.surface1,
            .bg = background,
        });
        const target: u16 = @intCast(@as(u32, line) * max_scroll / area.h);
        context.hits.add(.{ .x = area.x, .y = area.y + line, .w = 1, .h = 1 }, .{ .sidebar_scroll_to = target });
    }
}

fn drawFooter(context: *widget.Context, area: ui.Rect, y: u16, background: ui.Color) void {
    const row: ui.Rect = .{ .x = area.x, .y = y, .w = area.w, .h = 1 };
    context.buffer.fill(row, " ", .{ .bg = background });
    var x = row.x + 1;
    const hints = [_][2][]const u8{
        .{ "\u{21b5}", "open" },
        .{ "/", "search" },
        .{ "n", "new" },
        .{ "r", "review" },
    };
    for (hints) |hint| {
        const width = ui.measure(hint[0]) + ui.measure(hint[1]) + 3;
        if (x + width >= row.x + row.w - 3) break;
        x += context.buffer.writeText(row, x, y, hint[0], .{
            .fg = context.palette.accent,
            .bg = background,
            .flags = .{ .bold = true },
        });
        x += context.buffer.writeText(row, x, y, " ", .{ .bg = background });
        x += context.buffer.writeText(row, x, y, hint[1], .{
            .fg = context.palette.subtext0,
            .bg = background,
        });
        x += 2;
    }
    _ = context.buffer.writeRight(.{ .x = row.x, .y = y, .w = row.w -| 1, .h = 1 }, y, "^g", .{
        .fg = context.palette.overlay0,
        .bg = background,
    });
}

fn drawRule(context: *widget.Context, area: ui.Rect, y: u16, background: ui.Color) u16 {
    const style: ui.Style = .{ .fg = context.palette.surface1, .bg = background };
    // Tees belong to the frame, not the rule: keep the border color continuous.
    const tee_style: ui.Style = .{ .fg = context.palette.overlay0, .bg = background };
    var x = area.x + 1;
    while (x < area.x + area.w - 1) : (x += 1) _ = context.buffer.writeText(area, x, y, "\u{2500}", style);
    _ = context.buffer.writeText(area, area.x, y, "\u{251c}", tee_style);
    _ = context.buffer.writeText(area, area.x + area.w - 1, y, "\u{2524}", tee_style);
    return y + 1;
}

fn cellBackground(context: *const widget.Context, transparent: bool) ui.Color {
    return if (transparent) .default else context.palette.panel_bg;
}

fn sectionColor(context: *const widget.Context, section: Section) ui.Color {
    return switch (section) {
        .needs_you, .running => context.palette.accent,
        .ready => context.palette.green,
        .background => context.palette.overlay0,
    };
}

fn taskActionColor(context: *const widget.Context, action: TaskAction) ui.Color {
    return switch (action) {
        .none => context.palette.overlay0,
        .decide => context.palette.accent,
        .debug => context.palette.red,
        .review => context.palette.green,
    };
}

fn statusColor(context: *const widget.Context, status: Status) ui.Color {
    return switch (status) {
        .unknown, .queued => context.palette.overlay0,
        .waiting, .working => context.palette.accent,
        .failed => context.palette.red,
        .ready => context.palette.green,
    };
}

test "empty snapshot renders complete sidebar chrome and search hit" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 62, 32);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var state: State = .{};
    const snapshot: Snapshot = .{};
    const palette = @import("../theme.zig").default_theme.palette;
    var context: widget.Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &palette,
        .hovered = null,
    };
    const output = render(&context, .{
        .area = buffer.area(),
        .snapshot = &snapshot,
        .state = &state,
        .transparent = false,
    });
    try std.testing.expectEqual(widget.Action.sidebar_focus_search, hits.at(3, 1).?);
    try std.testing.expect(output.cursor == null);
    try std.testing.expectEqualStrings("t", buffer.at(3, 0).?.text());
}

test "task snapshot drives three-row cards and stable semantic actions" {
    var snapshot: Snapshot = .{};
    const tasks = [_]TaskInput{.{
        .key = .{ .id = 41, .generation = 3 },
        .title = "Fix auth token refresh",
        .place = "guruwalk/api",
        .place_detail = "fix-auth-refresh",
        .tool = "claude/opus",
        .note = "agent asks about token reuse",
        .section = .needs_you,
        .action = .decide,
        .provider = .claude,
        .status = .waiting,
    }};
    _ = try snapshot.replace(.{ .revision = 1, .tasks = &tasks });
    var buffer = try ui.Buffer.init(std.testing.allocator, 62, 32);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var state: State = .{ .selected_task = tasks[0].key };
    const palette = @import("../theme.zig").default_theme.palette;
    var context: widget.Context = .{ .buffer = &buffer, .hits = &hits, .palette = &palette, .hovered = null };
    const output = render(&context, .{
        .area = buffer.area(),
        .snapshot = &snapshot,
        .state = &state,
        .transparent = true,
    });
    try std.testing.expect(output.selected_card != null);
    try std.testing.expectEqual(@as(u16, 3), output.selected_card.?.h);
    try std.testing.expectEqual(@as(u8, 1), output.provider_mark_count);
    try std.testing.expectEqual(@as(u8, 3), output.control_count);
    try std.testing.expectEqualStrings("F", buffer.at(3, output.selected_card.?.y).?.text());
    try std.testing.expectEqualDeep(
        widget.Action{ .sidebar_select_task = tasks[0].key },
        hits.at(4, output.selected_card.?.y + 1).?,
    );
}

test "search is fixed capacity editable state and filters without allocation" {
    var state: State = .{ .search_active = true };
    try std.testing.expect(state.handleKey(.{ .code = .{ .char = .init("a") } }));
    try std.testing.expectEqualStrings("a", state.search.text());
    try std.testing.expect(state.paste("bc\ndef"));
    try std.testing.expectEqualStrings("abc def", state.search.text());
}
