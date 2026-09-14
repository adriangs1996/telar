//! The native command palette: one rounded surface with the prefixed field,
//! up to sixteen result rows and the prefix legend. It reads the client's
//! canonical results for every mode and never scores anything itself.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Canvas = @import("../chrome/Canvas.zig");
const Modal = @import("Modal.zig");
const PaletteHits = @import("PaletteHits.zig");
const PaletteRow = @import("PaletteRow.zig");
const Label = @import("../chrome/Label.zig");
const key_label = @import("key_label.zig");
const Router = @import("../input/router.zig").Type;
const CommandPalette = @This();

pub const max_rows = PaletteHits.capacity;
/// Logical width; converted to cells through the host scale.
pub const width_px = 620;
/// The top edge sits at this share of the host height.
pub const top_percent = 11;
pub const radius_px = 10;
/// Footer tokens; each stays under the shaping cache's entry size so a warm
/// frame shapes nothing. The active prefix token is painted in the accent.
/// Icons and key words use glyphs the embedded faces cover.
pub const legend = [_][]const u8{ ">", "actions", "@", "agents & panes", "?", "suggest", "↑↓", "select", "enter", "run", "esc", "close" };

canvas: *Canvas,
projection: client.Projection,
/// The native keymap that prints bound chords next to actions; absent in
/// fixtures without a window.
router: ?*const Router,
scale: f32,

/// Cells the palette occupies for `rows` visible results, centered
/// horizontally and anchored at eleven percent of the host height. Tiny
/// hosts fall back to the shared modal bounds.
/// Example: `const area = palette.area(rows);`.
pub fn area(palette: CommandPalette, rows: u16) core.Rect {
    const host: core.Rect = .{ .w = palette.projection.host_size.cols, .h = palette.projection.host_size.rows };
    const scale = if (palette.scale > 0) palette.scale else 1;
    const cell: f32 = @floatFromInt(@max(palette.canvas.metrics.cell_width, 1));
    const wanted: u16 = @intFromFloat(@ceil(@as(f32, width_px) * scale / cell));
    const width = @min(@max(wanted, 24), @min(host.w -| 4, 140));
    const height = rows + 4;
    const top = @as(u16, @intCast(@as(u32, host.h) * top_percent / 100));
    if (host.w < 12 or top + height > host.h) {
        return Modal.bounds(host, .{ .w = width, .h = height });
    }

    return .{ .x = (host.w - width) / 2, .y = top, .w = width, .h = height };
}

/// Paints the palette and records one hit per visible row.
/// Example: `const area = try palette.paint(&pending.palette);`.
pub fn paint(palette: CommandPalette, hits: *PaletteHits) !core.Rect {
    hits.* = .{};
    const prompt = palette.projection.prompt.?;
    const canvas = palette.canvas;
    const colors = canvas.theme.palette;
    const scale = if (palette.scale > 0) palette.scale else 1;
    var goto_results: client.Results = .{};
    var action_results: client.CommandResults = .{};
    const total: u16 = switch (prompt.paletteMode()) {
        .goto => blk: {
            client.collect(palette.sources(), prompt.paletteQuery(), &goto_results);
            break :blk goto_results.len;
        },
        .actions => blk: {
            client.command_palette.collect(prompt.paletteQuery(), &action_results);
            break :blk action_results.len;
        },
        .suggest => 1,
    };
    const visible: u16 = @max(@min(total, max_rows), 1);
    const frame = palette.area(visible);
    try canvas.fillRounded(frame, .{ .radius = radius_px * scale, .color = colors.panel_bg });
    try canvas.ring(frame, .{ .width = scale, .radius = radius_px * scale, .color = colors.surface1 });

    const content = frame.inner(1);
    if (content.h < 3) {
        return frame;
    }

    try palette.paintField(content.row(0), prompt);
    const rows = content.splitTop(1)[1].splitBottom(1)[0];
    const selected: u16 = if (total == 0) 0 else @min(prompt.selection(), total - 1);
    const count = @min(rows.h, visible);
    const start = (selected + 1) -| count;
    hits.first = start;
    if (total == 0) {
        try canvas.text(rows.row(0).splitLeft(2)[1], .{ .text = "No matches", .color = colors.subtext0, .face = .sans });
    }

    for (0..@min(count, total)) |offset| {
        const index = start + @as(u16, @intCast(offset));
        const row = rows.row(@intCast(offset));
        hits.add(row);
        if (index == selected) {
            try canvas.fill(row, colors.surface0);
        }

        switch (prompt.paletteMode()) {
            .goto => try palette.paintPickerRow(row, goto_results.slice()[index].item),
            .actions => try palette.paintActionRow(row, action_results.slice()[index].index),
            .suggest => try palette.paintSuggestionRow(row),
        }
    }

    try palette.paintLegend(content.row(content.h - 1), prompt.paletteMode());
    return frame;
}

// Keys in the monospace face, words in sans; the active prefix in accent.
fn paintLegend(palette: CommandPalette, row: core.Rect, mode: client.command_palette.Prefix) !void {
    const canvas = palette.canvas;
    const colors = canvas.theme.palette;
    const cell: f32 = @floatFromInt(@max(canvas.metrics.cell_width, 1));
    var remaining = row;
    for (legend, 0..) |token, index| {
        const is_key = index % 2 == 0;
        const active = token.len == 1 and client.command_palette.Prefix.parse(token[0]) == mode;
        const label: Label = .{ .text = token, .color = if (active) colors.accent else colors.subtext0, .bold = active, .face = if (is_key) .mono else .sans };
        const used: u16 = @intFromFloat(@ceil(try canvas.measure(label) / cell));
        if (used + 1 > remaining.w) {
            return;
        }

        try canvas.text(remaining, label);
        remaining = remaining.splitLeft(used + @as(u16, if (is_key) 1 else 3))[1];
    }
}

fn sources(palette: CommandPalette) client.Sources {
    return .{ .agents = palette.projection.agents, .workspaces = palette.projection.workspaces, .tabs = palette.projection.tabs };
}

// The prefix byte is painted over the field text in the accent color; the
// field keeps it as ordinary text so editing never needs a second cursor.
fn paintField(palette: CommandPalette, row: core.Rect, prompt: client.Prompt) !void {
    const canvas = palette.canvas;
    const colors = canvas.theme.palette;
    var field = prompt.field;
    const view = field.view(row.w);
    try canvas.fill(row, colors.surface0);
    try canvas.text(row, .{ .text = view.text, .color = colors.text });
    if (!view.clipped_left and view.text.len != 0 and client.command_palette.Prefix.parse(view.text[0]) != null) {
        const cell = row.splitLeft(1)[0];
        try canvas.fill(cell, colors.surface0);
        try canvas.text(cell, .{ .text = view.text[0..1], .color = colors.accent, .bold = true });
    }

    try canvas.border(.{ .x = row.x + @min(view.cursor, row.w - 1), .y = row.y, .w = 1, .h = 1 }, colors.accent);
}

fn paintPickerRow(palette: CommandPalette, row: core.Rect, item: client.ModelGotoPickerItem) !void {
    var storage: [client.max_label_bytes]u8 = undefined;
    const label = client.describe(palette.sources(), item, &storage);
    const split = std.mem.indexOf(u8, label, "  ") orelse label.len;
    const icon: []const u8 = switch (item) {
        .workspace => "■",
        .tab => "□",
        .agent => "●",
    };
    const kind: []const u8 = switch (item) {
        .workspace => "context",
        .tab => "tab",
        .agent => "agent",
    };
    try palette.paintRow(row, .{ .icon = icon, .primary = label[0..split], .secondary = std.mem.trimStart(u8, label[split..], " "), .hint = kind });
}

fn paintActionRow(palette: CommandPalette, row: core.Rect, index: u8) !void {
    const entry = client.command_palette.entries[index];
    var storage: [key_label.max_bytes]u8 = undefined;
    const hint: []const u8 = if (palette.router) |router| blk: {
        const key = router.prefixedKeyForAction(entry.action) orelse break :blk "";
        break :blk key_label.chord(&storage, router.prefix, key);
    } else "";
    try palette.paintRow(row, .{ .icon = "»", .primary = entry.label, .hint = hint });
}

fn paintSuggestionRow(palette: CommandPalette, row: core.Rect) !void {
    const state = palette.projection.suggestion;
    const colors = palette.canvas.theme.palette;
    const text: []const u8 = switch (state.phase) {
        .idle => "Describe the command you need",
        .waiting => "Asking the engine…",
        .ready => state.textSlice(),
        .failed => switch (state.status) {
            .ready => "The engine returned no command",
            .unavailable => "No engine configured (runtime.engine)",
            .timeout => "The engine timed out",
            .failed => "The engine could not answer",
        },
    };
    const hint: []const u8 = switch (state.phase) {
        .idle => "enter ask",
        .waiting => "esc cancel",
        .ready => "enter paste",
        .failed => "enter retry",
    };
    try palette.paintRow(row, .{ .icon = "?", .primary = text, .hint = hint, .mono = state.phase == .ready, .color = if (state.phase == .failed) colors.red else colors.text });
}

// Icon column, sans label, muted secondary text and a right-aligned
// monospace hint; the hint keeps its cells and the label clips before it.
fn paintRow(palette: CommandPalette, row: core.Rect, content: PaletteRow) !void {
    const canvas = palette.canvas;
    const colors = canvas.theme.palette;
    const parts = row.splitLeft(2);
    try canvas.text(parts[0], .{ .text = content.icon, .color = colors.subtext0 });
    const hint_cells = core.measure(content.hint);
    const body = parts[1].splitLeft(parts[1].w -| (hint_cells + 1))[0];
    const hint_area: core.Rect = .{ .x = row.x + row.w - hint_cells, .y = row.y, .w = hint_cells, .h = 1 };
    try canvas.text(hint_area, .{ .text = content.hint, .color = colors.subtext0 });
    const primary_label: Label = .{ .text = content.primary, .color = content.color orelse colors.text, .face = if (content.mono) .mono else .sans };
    try canvas.text(body, primary_label);
    if (content.secondary.len == 0 or body.w < 4) {
        return;
    }

    const cell: f32 = @floatFromInt(@max(canvas.metrics.cell_width, 1));
    const used: u16 = @intFromFloat(@ceil(try canvas.measure(primary_label) / cell));
    const rest = body.splitLeft(used + 1)[1];
    try canvas.text(rest, .{ .text = content.secondary, .color = colors.subtext0, .face = .sans });
}
