//! The native path picker: a popover anchored at the focused pane's cursor
//! with the search field on the edge next to it, up to ten matches and the
//! key hints on the far edge. Rows come from the runtime already ranked;
//! nothing here scores or sorts.

const cellgrid = @import("cellgrid");
const data = @import("model");
const std = @import("std");
const client = @import("telar-client");
const Canvas = @import("../Canvas.zig");
const TextField = @import("../TextField.zig");
const Label = @import("../Label.zig");
const PaletteHits = @import("PaletteHits.zig");
const key_label = @import("key_label.zig");
const PathPicker = @This();

pub const max_rows = 10;
pub const width_cells = 72;
pub const radius_px = 8;
/// Nerd Font folder and file glyphs; the embedded symbols face covers both.
const folder_icon = "\u{f07b}";
const file_icon = "\u{f15b}";
/// Key, word pairs; the host style picks glyphs or words.
const mac_hints = [_][]const u8{ "↵", "insert", "⇥", "open", "⇧⇥", "up", "⌥↵", "absolute", "esc", "close" };
const pc_hints = [_][]const u8{ "enter", "insert", "tab", "open", "shift+tab", "up", "alt+enter", "absolute", "esc", "close" };
const hints = if (key_label.host_style == .mac) mac_hints else pc_hints;

projection: *const client.Projection,
hits: *PaletteHits,
modal: *?cellgrid.Rect,
scale: f32,

/// Paints the picker and records one hit per visible row.
/// Example: `try picker.draw(canvas);`
pub fn draw(self: PathPicker, canvas: *Canvas) !void {
    self.hits.* = .{};
    const prompt = self.projection.prompt.?;
    const state = self.projection.path_picker;
    const colors = canvas.theme.palette;
    const scale = if (self.scale > 0) self.scale else 1;
    const visible: u16 = @max(@min(state.len, max_rows), 1);
    const placement = data.path_picker_placement.place(
        self.host(),
        self.cursor(),
        width_cells,
        visible + 4,
    );
    const frame = placement.area;
    self.modal.* = frame;
    try canvas.fillRounded(
        frame,
        .{
            .radius = radius_px * scale,
            .color = canvas.covering(colors.surface0),
        },
    );
    try canvas.ring(
        frame,
        .{
            .width = scale,
            .radius = radius_px * scale,
            .color = colors.surface1,
        },
    );

    const content = frame.inner(1);
    if (content.h < 3) {
        return;
    }

    const field_row = if (placement.flipped) content.row(content.h - 1) else content.row(0);
    const footer_row = if (placement.flipped) content.row(0) else content.row(content.h - 1);
    const rows = content.splitTop(1)[1].splitBottom(1)[0];
    try drawField(
        canvas,
        field_row,
        .{
            .prompt = prompt,
            .state = state,
        },
    );

    const total: u16 = state.len;
    const selected: u16 = if (total == 0) 0 else @min(prompt.selection(), total - 1);
    const count = @min(rows.h, @min(total, max_rows));
    const start = (selected + 1) -| count;
    self.hits.first = start;
    if (total == 0) {
        const empty_row = if (placement.flipped) rows.row(rows.h - 1) else rows.row(0);
        try canvas.text(
            empty_row.splitLeft(2)[1],
            .{
                .text = emptyText(state),
                .color = colors.subtext0,
                .face = .sans,
                .size = .body,
            },
        );
    }

    for (0..count) |offset| {
        const index = start + @as(u16, @intCast(offset));
        const row = if (placement.flipped) rows.row(rows.h - 1 - @as(u16, @intCast(offset))) else rows.row(@intCast(offset));
        self.hits.add(row);
        if (index == selected) {
            try canvas.fill(row, colors.surface1);
        }

        try drawMatch(
            canvas,
            row,
            .{
                .state = state,
                .match = &state.slice()[index],
            },
        );
    }

    try drawFooter(
        canvas,
        footer_row,
        state,
    );
}

fn host(self: PathPicker) cellgrid.Rect {
    return .{
        .w = self.projection.host_size.cols,
        .h = self.projection.host_size.rows,
    };
}

fn cursor(self: PathPicker) ?cellgrid.Point {
    const tab = self.projection.tab orelse return null;
    const layout = self.projection.layout orelse return null;
    return data.path_picker_placement.cursorCell(
        self.projection.model,
        tab,
        layout,
    );
}

const FieldInput = struct {
    prompt: data.Prompt,
    state: *const data.PathPickerState,
};

/// The root in muted text before the editable query, and the match count
/// at the right edge.
fn drawField(canvas: *Canvas, row: cellgrid.Rect, input: FieldInput) !void {
    const colors = canvas.theme.palette;
    var count_storage: [32]u8 = undefined;
    const count = std.fmt.bufPrint(
        &count_storage,
        "{d} of {d}",
        .{ input.state.len, input.state.scanned },
    ) catch "";
    const count_cells = @min(cellgrid.text.measure(count), row.w / 4);
    const parts = row.splitLeft(row.w -| (count_cells + 1));
    try canvas.text(
        parts[1].splitLeft(1)[1],
        .{
            .text = count,
            .color = colors.subtext0,
        },
    );

    const root = rootLabel(input.state.rootSlice());
    const root_cells = @min(cellgrid.text.measure(root) + 1, parts[0].w / 2);
    const field = parts[0].splitLeft(root_cells);
    try canvas.text(
        field[0],
        .{
            .text = root,
            .color = colors.subtext0,
        },
    );
    try TextField.fromPrompt(
        &input.prompt,
        canvas.rect(field[1]),
        .name,
    ).draw(canvas);
}

/// The root's last segment with a trailing `/`, as it reads before a query.
fn rootLabel(root: []const u8) []const u8 {
    if (root.len <= 1) {
        return "/";
    }

    const split = std.mem.lastIndexOfScalar(
        u8,
        root,
        '/',
    ) orelse return root;
    return root[split + 1 ..];
}

const MatchInput = struct {
    state: *const data.PathPickerState,
    match: *const data.PathPickerMatch,
};

fn drawMatch(canvas: *Canvas, row: cellgrid.Rect, input: MatchInput) !void {
    const colors = canvas.theme.palette;
    const directory = input.match.kind == .directory;
    const parts = row.splitLeft(3);
    try canvas.text(
        parts[0].splitLeft(1)[1],
        .{
            .text = if (directory) folder_icon else file_icon,
            .color = if (directory) colors.blue else colors.subtext0,
        },
    );

    var label: data.PathLabel = .{};
    label.layout(
        input.state.path(input.match),
        input.match.positions[0..input.match.position_count],
        parts[1].w,
    );
    var remaining = parts[1];
    for (label.slice()) |run| {
        const cells = cellgrid.text.measure(run.text);
        if (remaining.w == 0) {
            return;
        }

        try canvas.text(remaining.splitLeft(cells)[0], .{
            .text = run.text,
            .color = switch (run.tone) {
                .directory, .ellipsis => colors.subtext0,
                .name => colors.text,
                .match => colors.accent,
            },
            .bold = run.tone == .match,
        });
        remaining = remaining.splitLeft(cells)[1];
    }
}

fn drawFooter(canvas: *Canvas, row: cellgrid.Rect, state: *const data.PathPickerState) !void {
    const colors = canvas.theme.palette;
    var status_storage: [64]u8 = undefined;
    const failed = state.phase == .failed;
    const status = statusText(state, &status_storage);
    const status_label: Label = .{
        .text = status,
        .color = if (failed) colors.red else colors.subtext0,
        .face = .sans,
        .size = .body,
    };
    try canvas.text(row, status_label);

    const cell: f32 = @floatFromInt(@max(canvas.metrics.cell_width, 1));
    const used: u16 = @intFromFloat(@ceil(try canvas.measure(status_label) / cell));
    var remaining = row.splitLeft(used + 3)[1];
    var index: usize = 0;
    while (index + 1 < hints.len) : (index += 2) {
        const key: Label = .{
            .text = hints[index],
            .color = colors.text,
        };
        const word: Label = .{
            .text = hints[index + 1],
            .color = colors.subtext0,
            .face = .sans,
            .size = .body,
        };
        const key_cells = cellgrid.text.measure(hints[index]);
        const word_cells: u16 = @intFromFloat(@ceil(try canvas.measure(word) / cell));
        if (key_cells + word_cells + 1 > remaining.w) {
            return;
        }

        try canvas.text(remaining, key);
        remaining = remaining.splitLeft(key_cells + 1)[1];
        try canvas.text(remaining, word);
        remaining = remaining.splitLeft(word_cells + 2)[1];
    }
}

fn statusText(state: *const data.PathPickerState, storage: *[64]u8) []const u8 {
    if (state.phase == .failed) {
        return state.errorSlice();
    }

    if (!state.complete) {
        return std.fmt.bufPrint(
            storage,
            "indexing · {d}",
            .{state.scanned},
        ) catch "indexing";
    }

    if (state.truncated) {
        return std.fmt.bufPrint(
            storage,
            "{d}+ paths",
            .{state.scanned},
        ) catch "";
    }

    return std.fmt.bufPrint(
        storage,
        "{d} paths",
        .{state.scanned},
    ) catch "";
}

fn emptyText(state: *const data.PathPickerState) []const u8 {
    return switch (state.phase) {
        .idle, .loading => "Searching…",
        .failed => "No paths",
        .ready => if (state.complete) "No paths match" else "Searching…",
    };
}
