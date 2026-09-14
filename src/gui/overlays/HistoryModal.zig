const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const Modal = @import("Modal.zig");
const HistoryDetails = @import("HistoryDetails.zig");
const WrappedLines = @import("WrappedLines.zig");
const labels = @import("history_labels.zig");

const Canvas = @import("../chrome/Canvas.zig");
const HistoryModal = @This();

area: @import("telar-core").Rect,
projection: *const client.Projection,

/// Shares one responsive layout between drawing and inspector scroll bounds.
/// Example: `const modal_area = preferredArea(projection);`.
pub fn preferredArea(projection: client.Projection) core.Rect {
    const inspecting = projection.prompt.?.inspecting();
    return Modal.bounds(.{ .w = projection.host_size.cols, .h = projection.host_size.rows }, .{
        .w = if (inspecting) 140 else 104,
        .h = if (inspecting) 30 else @min(@max(projection.history.len, 1), 16) + 7,
    });
}

/// Draws a bounded history page and its captured output through native glyphs.
/// Example: `try widget.draw(canvas);`
pub fn draw(widget: HistoryModal, canvas: *Canvas) !void {
    const modal: Modal = .{ .canvas = canvas, .area = widget.area };
    const projection = widget.projection.*;
    const palette = modal.canvas.theme.palette;
    const prompt = projection.prompt.?;
    const state = projection.history;
    try modal.frame(if (state.match_fuzzy and prompt.field.text().len != 0) "History | fuzzy: newest 1000" else "History");
    try pageRange(modal, state);
    const content = modal.content();

    if (content.h <= 3) {
        try modal.field(content.row(0), prompt);
        return;
    }

    const list = content.splitBottom(3)[0];
    const selected: ?u16 = if (state.len == 0) null else @min(prompt.selection(), state.len - 1);
    if (prompt.inspecting() and selected != null) {
        if (list.w >= 100) {
            try rows(modal, projection, list.splitLeft(list.w / 2)[0]);
        }

        try inspect(modal, projection, inspectionArea(list));
    } else {
        try rows(modal, projection, list);
    }

    var storage: [512]u8 = undefined;
    const detail = if (state.errorSlice().len != 0)
        state.errorSlice()
    else if (selected) |index|
        std.fmt.bufPrint(&storage, "{s}  {s}  pane {d}  #{d}{s}", .{ state.slice()[index].cwdSlice(), @tagName(state.slice()[index].author), core.raw(state.slice()[index].pane_id), state.slice()[index].id, if (state.has_more) "  +more" else "" }) catch ""
    else
        "No selection";
    try modal.line(content.h - 3, .{ .text = detail, .color = if (state.errorSlice().len == 0) palette.subtext0 else palette.red });

    const prefix = std.fmt.bufPrint(&storage, "[{s}] > ", .{@tagName(state.effective_scope)}) catch "> ";
    const query = content.row(content.h - 2);
    const prefix_width = @min(core.measure(prefix), query.w -| 1);
    try modal.canvas.fill(query, palette.surface0);
    try modal.canvas.text(query.splitLeft(prefix_width)[0], .{ .text = prefix, .color = palette.accent });
    try modal.field(query.splitLeft(prefix_width)[1], prompt);

    const hint = if (prompt.inspecting())
        "^O back  PgUp/PgDn scroll  Up/Down select  Esc back"
    else if (state.enter_runs)
        "Enter run  Shift+Enter paste  Tab scope  ^O inspect  Esc close"
    else
        "Enter paste  Shift+Enter run  Tab scope  ^O inspect  Esc close";
    try modal.line(content.h - 1, .{ .text = hint, .color = palette.subtext0 });
}

fn rows(modal: Modal, projection: client.Projection, list: core.Rect) !void {
    const state = projection.history;
    const palette = modal.canvas.theme.palette;
    if (state.len == 0) {
        try modal.canvas.text(list.row(0), .{ .text = if (state.initialLoading()) "Searching..." else "No matching commands", .color = palette.subtext0 });
        return;
    }

    const selected = @min(projection.prompt.?.selection(), state.len - 1);
    const count = @min(list.h, state.len);
    const start = (selected + 1) -| count;
    for (0..count) |offset| {
        const index: u16 = @intCast(start + offset);
        const entry = &state.slice()[index];
        const row = list.row(list.h - 1 - @as(u16, @intCast(offset)));
        const active = index == selected;
        if (active) {
            try modal.canvas.fill(row, palette.surface1);
        }

        var storage: [40]u8 = undefined;
        const marker = std.fmt.bufPrint(&storage, "{s} {s}", .{ if (active) ">" else " ", if (entry.status == .running) "run" else if (entry.status == .interrupted) "stop" else if (entry.exit_code) |code| std.fmt.bufPrint(storage[16..], "{d}", .{code}) catch "?" else "?" }) catch "";
        const prefix = row.splitLeft(@min(row.w, 7));
        try modal.canvas.text(prefix[0], .{ .text = marker, .color = if (entry.exit_code != null and entry.exit_code.? != 0) palette.red else palette.green });
        var remaining = prefix[1];
        if (row.w >= 40) {
            try modal.canvas.text(remaining.splitLeft(7)[0], .{ .text = labels.duration(entry.duration_ns, &storage), .color = palette.yellow });
            remaining = remaining.splitLeft(8)[1];
        }

        if (row.w >= 64) {
            try modal.canvas.text(remaining.splitLeft(7)[0], .{ .text = labels.age(state.now_ms -| entry.started_at_ms, &storage), .color = palette.subtext0 });
            remaining = remaining.splitLeft(8)[1];
        }

        try command(modal, remaining, .{ .text = state.commandAt(index) orelse entry.commandSlice(), .query = projection.prompt.?.field.text() });
    }
}

fn command(modal: Modal, row: core.Rect, value: struct { text: []const u8, query: []const u8 }) !void {
    const palette = modal.canvas.theme.palette;
    try modal.canvas.text(row, .{ .text = value.text, .color = palette.text });
    var iterator: core.GraphemeIterator = .{ .bytes = value.text };
    var column: u16 = 0;
    var matched: usize = 0;
    while (column < row.w and matched < value.query.len) {
        const cluster = iterator.next() orelse break;
        if (cluster.width > row.w - column) {
            break;
        }

        if (cluster.bytes.len <= value.query.len - matched and std.ascii.eqlIgnoreCase(cluster.bytes, value.query[matched..][0..cluster.bytes.len])) {
            try modal.canvas.text(.{ .x = row.x + column, .y = row.y, .w = cluster.width, .h = 1 }, .{ .text = cluster.bytes, .color = palette.accent, .bold = true });
            matched += cluster.bytes.len;
        }

        column += cluster.width;
    }
}

fn pageRange(modal: Modal, state: *const client.HistoryPaletteState) !void {
    if (modal.area.w < 60) {
        return;
    }

    var storage: [48]u8 = undefined;
    const text = std.fmt.bufPrint(&storage, "{d}-{d}{s}", .{ @as(u64, state.page_offset) + @intFromBool(state.len != 0), @as(u64, state.page_offset) + state.len, if (state.has_more) " +more" else "" }) catch "";
    const width = @min(core.measure(text), modal.area.w - 34);
    const row: core.Rect = .{ .x = modal.area.x + modal.area.w - width - 2, .y = modal.area.y, .w = width, .h = 1 };
    try modal.canvas.fill(row, modal.canvas.covering(modal.canvas.theme.palette.panel_bg));
    try modal.canvas.text(row, .{ .text = text, .color = modal.canvas.theme.palette.subtext0 });
}

fn inspect(modal: Modal, projection: client.Projection, list: core.Rect) !void {
    const selection = @min(projection.prompt.?.selection(), projection.history.len - 1);
    var detail = HistoryDetails.init(projection.history, selection);
    var skip = projection.prompt.?.detailScroll();
    var row: u16 = 0;
    const palette = modal.canvas.theme.palette;
    for (detail.texts(), 0..) |text, index| {
        var lines: WrappedLines = .{ .text = text, .width = list.w };
        while (lines.next()) |line| {
            if (skip != 0) {
                skip -= 1;
                continue;
            }

            if (row == list.h) {
                return;
            }

            try modal.canvas.text(list.row(row), .{ .text = line, .color = if (index == 0 or index == 6) palette.accent else if (index == 1) palette.text else palette.subtext0 });
            row += 1;
        }
    }
}

fn inspectionArea(list: core.Rect) core.Rect {
    return if (list.w >= 100) list.splitLeft(list.w / 2 + 1)[1] else list;
}

/// Computes the exact rendered inspector's scroll bound only when needed.
/// Example: `const limit = inspectionScrollLimit(projection) orelse return;`.
pub fn inspectionScrollLimit(projection: client.Projection) ?u32 {
    const prompt = projection.prompt orelse return null;
    const state = projection.history;
    if (prompt.target() != .history or !prompt.inspecting() or prompt.detailScroll() == 0 or state.phase != .ready or state.len == 0) {
        return null;
    }

    const rect = preferredArea(projection);
    const content = if (rect.w > 2 and rect.h > 2) rect.inner(1) else rect;
    const list = inspectionArea(content.splitBottom(3)[0]);
    const selection = @min(prompt.selection(), state.len - 1);
    var detail = HistoryDetails.init(state, selection);
    var count: u32 = 0;
    for (detail.texts()) |text| {
        const lines: WrappedLines = .{ .text = text, .width = list.w };
        count += lines.count();
    }

    return count -| list.h;
}
