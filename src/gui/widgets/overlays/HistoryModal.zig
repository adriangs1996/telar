//! Native command history, sharing only query and selection semantics with TUI.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const Canvas = @import("../Canvas.zig");
const Rect = @import("../../render/Rect.zig");
const TextField = @import("../TextField.zig");
const FormButton = @import("../FormButton.zig");
const HistoryDetails = @import("HistoryDetails.zig");
const WrappedLines = @import("WrappedLines.zig");
const Metrics = @import("HistoryModalMetrics.zig");
const Layout = @import("HistoryModalLayout.zig");
const HistoryModal = @This();

layout: Layout,
projection: *const client.Projection,
reveal: f32 = 1,

/// All controls use the same animated pixel layout as the painted surface.
/// Example: `try widget.draw(canvas);`
pub fn draw(widget: HistoryModal, canvas: *Canvas) !void {
    const first = canvas.quads.items().len;
    try (@import("DialogSurface.zig"){ .bounds = widget.layout.bounds, .viewport = widget.layout.viewport }).draw(canvas);
    const content = canvas.quads.items().len;
    try widget.header(canvas);
    try widget.search(canvas);
    try widget.summary(canvas);
    try widget.rows(canvas);
    if (widget.projection.prompt.?.inspecting() and widget.projection.history.len != 0) {
        try widget.inspect(canvas);
    }

    try widget.footer(canvas);
    canvas.quads.clipFrom(content, widget.layout.bounds);
    canvas.quads.clipFrom(first, widget.layout.viewport);
    canvas.quads.fadeFrom(first, widget.reveal);
}

fn header(widget: HistoryModal, canvas: *Canvas) !void {
    const area = widget.layout.header;
    const close_width = @min(canvas.chrome.px(30), area.width);
    const prompt = widget.projection.prompt.?;
    var heading = canvas.*;
    heading.chrome.title = @intFromFloat(@max(canvas.chrome.px(20), @as(f32, @floatFromInt(canvas.chrome.title))));
    _ = try heading.textAt(.{ .x = area.x, .y = area.y, .width = @max(0, area.width - close_width - canvas.chrome.px(8)), .height = area.height }, .{ .text = "Command history", .face = .sans, .size = .title, .bold = true, .color = canvas.theme.palette.text });
    try (FormButton{ .bounds = .{ .x = area.x + area.width - close_width, .y = area.y, .width = close_width, .height = area.height }, .text = if (prompt.inspecting()) "‹" else "×", .label = if (prompt.inspecting()) "Back to history" else "Close history", .action = .{ .prompt = .cancel }, .generation = prompt.generation, .namespace = 1, .quiet = true }).draw(canvas);
}

fn search(widget: HistoryModal, canvas: *Canvas) !void {
    const prompt = widget.projection.prompt.?;
    var field = TextField.fromPrompt(&prompt, widget.layout.search, .name);
    field.form_control = true;
    field.label = "Search command history";
    field.placeholder = "Search commands…";
    try field.draw(canvas);
    const scope = switch (widget.projection.history.effective_scope) {
        .global => "All history  Tab",
        .cwd => "Directory  Tab",
        .workspace => "Workspace  Tab",
        .pane => "This pane  Tab",
    };
    try (FormButton{ .bounds = widget.layout.scope, .text = scope, .label = "Change history scope (Tab)", .action = .{ .history = .cycle_scope }, .generation = prompt.generation, .namespace = 2 }).draw(canvas);
}

fn summary(widget: HistoryModal, canvas: *Canvas) !void {
    const history = widget.projection.history;
    const area = widget.layout.summary;
    const palette = canvas.theme.palette;
    var storage: [100]u8 = undefined;
    const text = if (history.len == 0)
        (if (history.initialLoading()) "Searching…" else "Commands")
    else
        std.fmt.bufPrint(&storage, "{d}–{d} commands{s}", .{ @as(u64, history.page_offset) + 1, @as(u64, history.page_offset) + history.len, if (history.has_more) " +" else "" }) catch "Commands";
    const width = try canvas.textAt(area, .{ .text = text, .face = .sans, .size = .small, .color = palette.subtext0 });
    if (history.match_fuzzy and widget.projection.prompt.?.field.text().len != 0) {
        const label: @import("../Label.zig") = .{ .text = "Fuzzy search · newest 1,000", .face = .sans, .size = .small, .color = palette.subtext0 };
        const fuzzy_width = try canvas.measure(label);
        if (area.width > width + fuzzy_width + canvas.chrome.px(20)) {
            _ = try canvas.textAt(.{ .x = area.x + area.width - fuzzy_width, .y = area.y, .width = fuzzy_width, .height = area.height }, label);
        }
    }
}

fn rows(widget: HistoryModal, canvas: *Canvas) !void {
    const layout = widget.layout;
    if (layout.results.width <= 0 or layout.rows == 0) {
        return;
    }

    const history = widget.projection.history;
    if (history.len == 0) {
        const height = canvas.chrome.rowHeight(.body);
        const area: Rect = .{ .x = layout.results.x + canvas.chrome.px(12), .y = layout.results.y + @max(0, (layout.results.height - height * 2) / 2), .width = @max(0, layout.results.width - canvas.chrome.px(24)), .height = height };
        _ = try canvas.textAt(area, .{ .text = if (history.initialLoading()) "Searching your command history…" else "No matching commands", .face = .sans, .size = .body, .color = canvas.theme.palette.text });
        _ = try canvas.textAt(.{ .x = area.x, .y = area.y + height + canvas.chrome.px(6), .width = area.width, .height = height }, .{ .text = "Try a search or another scope.", .face = .sans, .size = .small, .color = canvas.theme.palette.subtext0 });
        return;
    }

    const selected = @min(widget.projection.prompt.?.selection(), history.len - 1);
    const count = @min(layout.rows, history.len);
    const start = (selected + 1) -| count;
    for (0..count) |offset| {
        const index: u16 = start + @as(u16, @intCast(offset));
        try (@import("HistoryRow.zig"){ .bounds = layout.row(@intCast(offset)), .projection = widget.projection, .index = index, .selected = index == selected }).draw(canvas);
    }
}

fn footer(widget: HistoryModal, canvas: *Canvas) !void {
    const history = widget.projection.history;
    const prompt = widget.projection.prompt.?;
    const palette = canvas.theme.palette;
    const layout = widget.layout;
    const selected: ?u16 = if (history.len == 0) null else @min(prompt.selection(), history.len - 1);
    var storage: [256]u8 = undefined;
    const detail = if (history.errorSlice().len != 0)
        history.errorSlice()
    else if (selected) |index|
        std.fmt.bufPrint(&storage, "{s}  ·  Pane {d}", .{ if (history.slice()[index].author == .human) "You" else "Agent", core.raw(history.slice()[index].pane_id) }) catch ""
    else
        "Reuse a command from your shell.";
    try (@import("../Caption.zig"){ .bounds = layout.detail, .label = .{ .text = detail, .face = .sans, .size = .small, .color = if (history.errorSlice().len == 0) palette.subtext0 else palette.red } }).draw(canvas);

    if (selected != null and history.errorSlice().len == 0) {
        const text = std.fmt.bufPrint(&storage, "Command #{d}", .{history.slice()[selected.?].id}) catch "";
        const label: @import("../Label.zig") = .{ .text = text, .face = .sans, .size = .small, .color = palette.subtext0 };
        const width = try canvas.measure(label);
        if (layout.detail.width > width + canvas.chrome.px(180)) {
            _ = try canvas.textAt(.{ .x = layout.detail.x + layout.detail.width - width, .y = layout.detail.y, .width = width, .height = layout.detail.height }, label);
        }
    }

    const area = layout.footer;
    const gap = @min(canvas.chrome.px(8), area.width / 12);
    const primary_width = @min(canvas.chrome.px(if (history.enter_runs) 104 else 116), area.width * 0.42);
    const inspect_width = @min(canvas.chrome.px(if (prompt.inspecting()) 154 else 126), @max(0, area.width - primary_width - gap));
    const primary: Rect = .{ .x = area.x + area.width - primary_width, .y = area.y, .width = primary_width, .height = area.height };
    const inspect_button: Rect = .{ .x = primary.x - inspect_width - gap, .y = area.y, .width = inspect_width, .height = area.height };
    try (FormButton{ .bounds = inspect_button, .text = if (prompt.inspecting()) "Hide details  Ctrl+O" else "Details  Ctrl+O", .action = .{ .history = .toggle_inspection }, .generation = prompt.generation, .namespace = 3, .enabled = selected != null and history.phase == .ready }).draw(canvas);
    try (FormButton{ .bounds = primary, .text = if (history.enter_runs) "Run  Enter" else "Paste  Enter", .action = .{ .history = .{ .submit = .{ .index = selected orelse 0, .revision = history.version() } } }, .generation = prompt.generation, .namespace = 0, .primary = true, .enabled = selected != null and history.phase == .ready }).draw(canvas);
    _ = try canvas.textAt(.{ .x = area.x, .y = area.y, .width = @max(0, inspect_button.x - area.x - gap), .height = area.height }, .{ .text = if (prompt.inspecting()) "PgUp / PgDn  Scroll output" else if (history.enter_runs) "↑ ↓ Select   Shift+Enter Paste" else "↑ ↓ Select   Shift+Enter Run", .face = .sans, .size = .small, .color = palette.subtext0 });
}

fn inspect(widget: HistoryModal, canvas: *Canvas) !void {
    const layout = widget.layout;
    const metrics = Metrics.fromCanvas(canvas);
    const content = layout.inspectionContent(metrics);
    const columns = columnsFor(content, metrics);
    const row_height: f32 = @floatFromInt(metrics.terminal.cell_height);
    if (columns == 0 or row_height <= 0) {
        return;
    }

    try canvas.fillRoundedAt(layout.inspection, .{ .color = canvas.theme.palette.surface0, .radius = canvas.chrome.px(8) });
    const first = canvas.quads.items().len;
    const selection = @min(widget.projection.prompt.?.selection(), widget.projection.history.len - 1);
    var detail = HistoryDetails.init(widget.projection.history, selection);
    var skip = widget.projection.prompt.?.detailScroll();
    var row: u16 = 0;
    const rows_count: u16 = @intFromFloat(@floor(content.height / row_height));
    for (detail.texts(), 0..) |text, index| {
        var lines: WrappedLines = .{ .text = text, .width = columns };
        while (lines.next()) |line| {
            if (skip != 0) {
                skip -= 1;
                continue;
            }

            if (row == rows_count) {
                canvas.quads.clipFrom(first, content);
                return;
            }

            _ = try canvas.textAt(.{ .x = content.x, .y = content.y + @as(f32, @floatFromInt(row)) * row_height, .width = content.width, .height = row_height }, .{ .text = line, .color = if (index == 0 or index == 6) canvas.theme.palette.accent else if (index == 1 or index == 7) canvas.theme.palette.text else canvas.theme.palette.subtext0 });
            row += 1;
        }
    }

    canvas.quads.clipFrom(first, content);
}

/// Counts exactly the native inspector's wrapped rows, without shaping text.
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
    var detail = HistoryDetails.init(history, @min(prompt.selection(), history.len - 1));
    var count: u32 = 0;
    for (detail.texts()) |text| {
        count += (WrappedLines{ .text = text, .width = columns }).count();
    }

    return count -| rows_count;
}

fn columnsFor(content: Rect, metrics: Metrics) u16 {
    return @intFromFloat(@min(65535, @floor(content.width / @as(f32, @floatFromInt(@max(1, metrics.terminal.cell_width))))));
}
