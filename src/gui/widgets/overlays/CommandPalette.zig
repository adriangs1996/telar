//! The native command palette: one rounded surface with the prefixed field,
//! up to sixteen result rows and the prefix legend. It reads the client's
//! canonical results for every mode and never scores anything itself.
const cellgrid = @import("cellgrid");
const TextField = @import("../TextField.zig");
const router_module = @import("../../input/router.zig");
const data = @import("model");
const std = @import("std");
const client = @import("telar-client");
const Canvas = @import("../Canvas.zig");
const Modal = @import("Modal.zig");
const PaletteHits = @import("PaletteHits.zig");
const PaletteRow = @import("PaletteRow.zig");
const SuggestionPanel = @import("SuggestionPanel.zig");
const Label = @import("../Label.zig");
const key_label = @import("key_label.zig");
const CommandPalette = @This();

pub const max_rows = PaletteHits.capacity;
/// Logical width; converted to cells through the host scale.
pub const width_px = 900;
/// The top edge sits at this share of the host height.
pub const top_percent = 11;
pub const radius_px = 10;
/// Footer tokens; each stays under the shaping cache's entry size so a warm
/// frame shapes nothing. The active prefix token is painted in the accent.
/// Icons and key words use glyphs the embedded faces cover.
pub const legend = [_][]const u8{ ">", "actions", "@", "agents & panes", "?", "suggest", "↑↓", "select", "enter", "run", "esc", "close" };

projection: *const client.Projection,
hits: *PaletteHits,
modal: *?cellgrid.Rect,
/// The native keymap that prints bound chords next to actions; absent in
/// fixtures without a window.
router: ?*const router_module.Type,
scale: f32,

/// Cells the palette occupies for `rows` visible results, centered
/// horizontally and anchored at eleven percent of the host height. Tiny
/// hosts fall back to the shared modal bounds.
/// Example: `const bounds = palette.area(canvas, rows);`
pub fn area(self: CommandPalette, canvas: *Canvas, rows: u16) cellgrid.Rect {
    const host: cellgrid.Rect = .{ .w = self.projection.host_size.cols, .h = self.projection.host_size.rows };
    const scale = if (self.scale > 0) self.scale else 1;
    const cell: f32 = @floatFromInt(@max(canvas.metrics.cell_width, 1));
    const wanted: u16 = @intFromFloat(@ceil(@as(f32, width_px) * scale / cell));
    const width = @min(@max(wanted, 24), @min(host.w -| 4, 140));
    const height: u16 = if (self.projection.prompt.?.paletteMode() == .suggest)
        SuggestionPanel.height(self.projection.suggestion, width)
    else
        rows + 4;
    const top = @as(u16, @intCast(@as(u32, host.h) * top_percent / 100));
    if (host.w < 12 or top + height > host.h) {
        return Modal.bounds(host, .{ .w = width, .h = height });
    }

    return .{ .x = (host.w - width) / 2, .y = top, .w = width, .h = height };
}

/// Paints the palette and records one hit per visible row.
/// Example: `try palette.draw(canvas);`
pub fn draw(self: CommandPalette, canvas: *Canvas) !void {
    const hits = self.hits;
    hits.* = .{};
    const prompt = self.projection.prompt.?;
    const colors = canvas.theme.palette;
    const scale = if (self.scale > 0) self.scale else 1;
    var goto_results: data.Results = .{};
    var action_results: data.CommandResults = .{};
    const total: u16 = switch (prompt.paletteMode()) {
        .goto => blk: {
            data.goto_picker.collect(self.sources(), prompt.paletteQuery(), &goto_results);
            break :blk goto_results.len;
        },
        .actions => blk: {
            data.command_palette.collect(prompt.paletteQuery(), &action_results);
            break :blk action_results.len;
        },
        .suggest => 1,
    };
    const visible: u16 = @max(@min(total, max_rows), 1);
    const frame = self.area(canvas, visible);
    self.modal.* = frame;
    try canvas.fillRounded(frame, .{ .radius = radius_px * scale, .color = canvas.covering(colors.panel_bg) });
    try canvas.ring(frame, .{ .width = scale, .radius = radius_px * scale, .color = colors.surface1 });

    const content = frame.inner(1);
    if (content.h < 3) {
        return;
    }

    if (prompt.paletteMode() == .suggest) {
        const inset: u16 = @min(2, content.w / 8);
        const suggestion_area: cellgrid.Rect = .{ .x = content.x + inset, .y = content.y, .w = content.w - inset * 2, .h = content.h };
        try (SuggestionPanel{ .area = suggestion_area, .projection = self.projection, .hits = hits }).draw(canvas);
        return;
    }

    try drawField(canvas, content.row(0), prompt);
    const rows = content.splitTop(1)[1].splitBottom(1)[0];
    const selected: u16 = if (total == 0) 0 else @min(prompt.selection(), total - 1);
    const count = @min(rows.h, visible);
    const start = (selected + 1) -| count;
    hits.first = start;
    if (total == 0) {
        try canvas.text(rows.row(0).splitLeft(2)[1], .{ .text = "No matches", .color = colors.subtext0, .face = .sans, .size = .body });
    }

    for (0..@min(count, total)) |offset| {
        const index = start + @as(u16, @intCast(offset));
        const row = rows.row(@intCast(offset));
        hits.add(row);
        if (index == selected) {
            try canvas.fill(row, colors.surface0);
        }

        var label_storage: [data.goto_picker.max_label_bytes]u8 = undefined;
        var key_storage: [key_label.max_bytes]u8 = undefined;
        var child = switch (prompt.paletteMode()) {
            .goto => self.pickerRow(goto_results.slice()[index].item, &label_storage),
            .actions => self.actionRow(action_results.slice()[index].index, &key_storage),
            .suggest => unreachable,
        };
        child.area = row;
        try child.draw(canvas);
    }

    try drawLegend(canvas, content.row(content.h - 1), prompt.paletteMode());
}

// Keys in the monospace face, words in sans; the active prefix in accent.
fn drawLegend(canvas: *Canvas, row: cellgrid.Rect, mode: data.command_palette.Prefix) !void {
    const colors = canvas.theme.palette;
    const cell: f32 = @floatFromInt(@max(canvas.metrics.cell_width, 1));
    var remaining = row;
    for (legend, 0..) |token, index| {
        const is_key = index % 2 == 0;
        const active = token.len == 1 and data.command_palette.Prefix.parse(token[0]) == mode;
        const label: Label = .{ .text = token, .color = if (active) colors.accent else colors.subtext0, .bold = active, .face = if (is_key) .mono else .sans, .size = .body };
        const used: u16 = @intFromFloat(@ceil(try canvas.measure(label) / cell));
        if (used + 1 > remaining.w) {
            return;
        }

        try canvas.text(remaining, label);
        remaining = remaining.splitLeft(used + @as(u16, if (is_key) 1 else 3))[1];
    }
}

fn sources(self: CommandPalette) data.Sources {
    return .{ .agents = self.projection.agents, .workspaces = self.projection.workspaces, .model = self.projection.model };
}

// The prefix byte is painted over the field text in the accent color; the
// field keeps it as ordinary text so editing never needs a second cursor.
fn drawField(canvas: *Canvas, row: cellgrid.Rect, prompt: data.Prompt) !void {
    const colors = canvas.theme.palette;
    var field = prompt.field;
    const view = field.view(row.w);
    try TextField.fromPrompt(&prompt, canvas.rect(row), .name).draw(canvas);
    if (!view.clipped_left and view.text.len != 0 and data.command_palette.Prefix.parse(view.text[0]) != null) {
        const cell = row.splitLeft(1)[0];
        try canvas.fill(cell, colors.surface0);
        try canvas.text(cell, .{ .text = view.text[0..1], .color = colors.accent, .bold = true });
    }
}

fn pickerRow(self: CommandPalette, item: data.goto_picker.Item, storage: *[data.goto_picker.max_label_bytes]u8) PaletteRow {
    const label = data.goto_picker.describe(self.sources(), item, storage);
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
    return .{ .icon = icon, .primary = label[0..split], .secondary = std.mem.trimStart(u8, label[split..], " "), .hint = kind };
}

fn actionRow(self: CommandPalette, index: u8, storage: *[key_label.max_bytes]u8) PaletteRow {
    const entry = data.command_palette.entries[index];
    const hint: []const u8 = if (self.router) |router| blk: {
        const key = router.prefixedKeyForAction(entry.action) orelse break :blk "";
        break :blk key_label.chord(storage, router.prefix, key);
    } else "";
    return .{ .icon = "»", .primary = entry.label, .hint = hint };
}
