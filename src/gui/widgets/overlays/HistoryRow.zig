//! One command on one line: a status glyph, the command in the terminal
//! face and its facts right-aligned in the chrome face. Facts drop from the
//! right when the row is narrow; the glyph and the command never drop.
const cellgrid = @import("cellgrid");
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const data = @import("model");
const Canvas = @import("../Canvas.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Target = @import("../interaction/Target.zig");
const labels = @import("history_labels.zig");
const Label = @import("../Label.zig");
const Row = @This();

/// Logical size of the provider mark, the sprite page's cell.
pub const mark_size: f32 = 16;

bounds: Rect,
projection: *const client.Projection,
index: u16,
selected: bool,
/// The time column: the clock under a day heading, the date when searching.
time: enum { clock, date } = .clock,
/// Directory and pane scopes make the directory column redundant.
show_cwd: bool = true,

/// Selecting a row never pastes or runs it. The delivered page revision guards
/// asynchronous replacements. Example: `try row.draw(canvas);`
pub fn draw(self: Row, canvas: *Canvas) !void {
    if (self.bounds.width <= 0 or self.bounds.height <= 0) {
        return;
    }

    const history = self.projection.history;
    const entry = &history.slice()[self.index];
    const command = history.commandAt(self.index) orelse entry.commandSlice();
    const palette = canvas.theme.palette;
    const px = canvas.chrome;
    const gap = px.px(10);
    const bounds: Rect = .{
        .x = self.bounds.x + px.px(8),
        .y = self.bounds.y + px.px(1),
        .width = @max(0, self.bounds.width - px.px(16)),
        .height = @max(0, self.bounds.height - px.px(2)),
    };
    var hovered = false;
    if (canvas.widgets) |state| {
        const target = (Target{
            .id = .{ .generation = self.projection.prompt.?.generation },
            .bounds = bounds,
            .action = .{ .history = .{ .select = .{ .index = self.index, .revision = history.version() } } },
            .layer = 1,
            .focusable = false,
            .enabled = history.phase == .ready,
        }).labelled(command);
        const id = try state.dispatcher.add(target);
        hovered = if (state.dispatcher.hovered) |hover| hover.eql(id) else false;
    }

    if (self.selected or hovered) {
        try canvas.fillRoundedAt(bounds, .{
            .color = if (self.selected) palette.surface1 else palette.surface0,
            .radius = px.px(8),
        });
    }
    if (self.selected) {
        try canvas.fillRoundedAt(.{
            .x = bounds.x,
            .y = bounds.y + px.px(7),
            .width = px.px(2),
            .height = @max(0, bounds.height - px.px(14)),
        }, .{
            .color = palette.accent,
            .radius = px.px(1),
        });
    }

    const status = statusOf(entry, palette);
    const symbol: Rect = .{
        .x = bounds.x + gap,
        .y = bounds.y,
        .width = px.px(20),
        .height = bounds.height,
    };
    _ = try canvas.textAt(symbol, .{
        .text = status.glyph,
        .color = status.color,
    });

    const facts_right = bounds.x + bounds.width - gap;
    const command_x = symbol.x + symbol.width + gap;
    const facts_width = try self.facts(canvas, .{
        .x = command_x + px.px(160),
        .y = bounds.y,
        .width = @max(0, facts_right - command_x - px.px(160)),
        .height = bounds.height,
    });
    const title: Rect = .{
        .x = command_x,
        .y = bounds.y,
        .width = @max(0, facts_right - command_x - (if (facts_width > 0) facts_width + px.px(14) else 0)),
        .height = bounds.height,
    };
    try self.commandText(canvas, .{ .bounds = title, .text = command });
}

/// Right-aligns the facts that fit inside `area`, dropping the time first,
/// then the duration, then the directory; the provider mark survives last.
/// Returns the painted width.
fn facts(self: Row, canvas: *Canvas, area: Rect) !f32 {
    const history = self.projection.history;
    const entry = &history.slice()[self.index];
    const palette = canvas.theme.palette;
    const px = canvas.chrome;
    const gap = px.px(14);
    var duration_storage: [32]u8 = undefined;
    var time_storage: [32]u8 = undefined;
    var path_storage: [labels.path_bytes]u8 = undefined;
    var exit_storage: [24]u8 = undefined;
    const time_text = switch (self.time) {
        .clock => labels.clock(entry.started_at_ms, history.utc_offset_min, &time_storage),
        .date => labels.dateLabel(entry.started_at_ms, history.now_ms, history.utc_offset_min, &time_storage),
    };
    const state: ?Label = switch (entry.status) {
        .running => .{ .text = "running", .color = palette.teal, .face = .sans, .size = .small },
        .interrupted => .{ .text = "stopped", .color = palette.yellow, .face = .sans, .size = .small },
        .completed => if (entry.exit_code) |code| (if (code != 0) Label{
            .text = std.fmt.bufPrint(&exit_storage, "exit {d}", .{code}) catch "exit",
            .color = palette.red,
            .face = .sans,
            .size = .small,
        } else null) else null,
    };
    var tokens: [5]Token = undefined;
    var count: usize = 0;
    if (entry.author == .agent) {
        tokens[count] = .{ .kind = .mark, .width = @round(px.px(mark_size)) };
        count += 1;
    }
    if (self.show_cwd and entry.cwd_len != 0) {
        const label: Label = .{ .text = labels.compactPath(entry.cwdSlice(), &path_storage), .color = palette.subtext0, .alpha = 0.85, .face = .sans, .size = .small };
        tokens[count] = .{ .kind = .label, .label = label, .width = try canvas.measure(label) };
        count += 1;
    }
    if (state) |label| {
        tokens[count] = .{ .kind = .label, .label = label, .width = try canvas.measure(label) };
        count += 1;
    }
    if (entry.status != .running) {
        const label: Label = .{ .text = labels.duration(entry.duration_ns, &duration_storage), .color = palette.subtext0, .face = .sans, .size = .small };
        tokens[count] = .{ .kind = .label, .label = label, .width = try canvas.measure(label) };
        count += 1;
    }
    if (entry.started_at_ms >= 0) {
        const label: Label = .{ .text = time_text, .color = palette.subtext0, .face = .sans, .size = .small };
        tokens[count] = .{ .kind = .label, .label = label, .width = try canvas.measure(label) };
        count += 1;
    }

    var total: f32 = 0;
    for (tokens[0..count]) |token| {
        total += token.width + gap;
    }
    while (count > 0 and total - gap > area.width) {
        count -= 1;
        total -= tokens[count].width + gap;
    }
    if (count == 0) {
        return 0;
    }

    total -= gap;
    var x = area.x + area.width - total;
    for (tokens[0..count]) |token| {
        switch (token.kind) {
            .mark => try self.mark(canvas, .{
                .x = x,
                .y = area.y + @floor((area.height - token.width) / 2),
                .width = token.width,
                .height = token.width,
            }),
            .label => _ = try canvas.textAt(.{
                .x = x,
                .y = area.y,
                .width = token.width,
                .height = area.height,
            }, token.label),
        }

        x += token.width + gap;
    }

    return total;
}

// A built-in provider shows its mark from the sprite page; any other agent
// shows the first letter of its manifest name on a small chip.
fn mark(self: Row, canvas: *Canvas, box: Rect) !void {
    const entry = &self.projection.history.slice()[self.index];
    const palette = canvas.theme.palette;
    const provider = providerOf(entry.providerSlice());
    if (canvas.providerMark(provider)) |sprite| {
        const tint: cellgrid.Color = if (data.icons.providerMarkFollowsTheme(provider))
            (if (palette.text.kind == .default) .rgb(canvas.theme.terminal.foreground) else palette.text)
        else
            .default;
        try canvas.spriteTintedAt(box, .{
            .sprite = sprite,
            .color = tint,
        });
        return;
    }

    try canvas.fillRoundedAt(box, .{
        .color = palette.surface1,
        .radius = canvas.chrome.px(3),
    });
    var letter_storage: [1]u8 = undefined;
    const name = entry.providerSlice();
    const letter: []const u8 = if (name.len != 0 and std.ascii.isAlphanumeric(name[0])) blk: {
        letter_storage[0] = std.ascii.toUpper(name[0]);
        break :blk letter_storage[0..1];
    } else "A";
    const label: Label = .{ .text = letter, .color = palette.text, .bold = true, .face = .sans, .size = .small };
    const width = try canvas.measure(label);
    _ = try canvas.textAt(.{
        .x = box.x + @max(0, (box.width - width) / 2),
        .y = box.y,
        .width = box.width,
        .height = box.height,
    }, label);
}

/// The built-in provider a history entry's manifest name denotes.
/// Example: `if (canvas.providerMark(HistoryRow.providerOf(entry.providerSlice()))) |mark| ...`
pub fn providerOf(name: []const u8) core.AgentProvider {
    return core.builtinProvider(name) orelse .unknown;
}

fn commandText(self: Row, canvas: *Canvas, value: struct { bounds: Rect, text: []const u8 }) !void {
    const cell: f32 = @floatFromInt(canvas.metrics.cell_width);
    const columns = @floor(value.bounds.width / cell);
    const needed = try canvas.measure(.{ .text = value.text });
    var bounds = value.bounds;
    if (needed > value.bounds.width and columns >= 2) {
        bounds.width = (columns - 1) * cell;
        _ = try canvas.textAt(.{
            .x = value.bounds.x + bounds.width,
            .y = value.bounds.y,
            .width = cell,
            .height = value.bounds.height,
        }, .{
            .text = "…",
            .color = canvas.theme.palette.subtext0,
        });
    }

    _ = try canvas.textAt(bounds, .{
        .text = value.text,
        .color = canvas.theme.palette.text,
    });
    const filters = client.history_palette.historyFilters(&self.projection.prompt.?, self.projection.prompt.?.field.text());
    const query = filters.query;
    var iterator: cellgrid.GraphemeIterator = .{ .bytes = value.text };
    var column: u16 = 0;
    var matched: usize = 0;
    while (@as(f32, @floatFromInt(column)) * cell < bounds.width and matched < query.len) {
        const cluster = iterator.next() orelse break;
        const width = @as(f32, @floatFromInt(cluster.width)) * cell;
        const x = @as(f32, @floatFromInt(column)) * cell;
        if (x + width > bounds.width) {
            break;
        }

        if (cluster.bytes.len <= query.len - matched and std.ascii.eqlIgnoreCase(cluster.bytes, query[matched..][0..cluster.bytes.len])) {
            _ = try canvas.textAt(.{
                .x = bounds.x + x,
                .y = bounds.y,
                .width = width,
                .height = bounds.height,
            }, .{
                .text = cluster.bytes,
                .color = canvas.theme.palette.accent,
                .bold = true,
            });
            matched += cluster.bytes.len;
        }

        column += cluster.width;
    }
}

const Status = struct {
    glyph: []const u8,
    color: cellgrid.Color,
};

// One color per meaning: success stays quiet, failure and interruption speak.
fn statusOf(entry: anytype, palette: anytype) Status {
    return switch (entry.status) {
        .running => .{ .glyph = "◌", .color = palette.teal },
        .interrupted => .{ .glyph = "■", .color = palette.yellow },
        .completed => if (entry.exit_code) |code| (if (code == 0) Status{ .glyph = "·", .color = palette.overlay0 } else Status{ .glyph = "✕", .color = palette.red }) else Status{ .glyph = "·", .color = palette.subtext0 },
    };
}

const Token = struct {
    kind: enum { mark, label },
    label: Label = .{ .text = "" },
    width: f32,
};

test "manifest names select the built-in provider mark or none" {
    try std.testing.expectEqual(core.AgentProvider.claude, providerOf("claude"));
    try std.testing.expectEqual(core.AgentProvider.codex, providerOf("codex"));
    try std.testing.expectEqual(core.AgentProvider.pi, providerOf("pi"));
    try std.testing.expectEqual(core.AgentProvider.cursor, providerOf("cursor"));
    try std.testing.expectEqual(core.AgentProvider.opencode, providerOf("opencode"));
    try std.testing.expectEqual(core.AgentProvider.unknown, providerOf("aider"));
    try std.testing.expectEqual(core.AgentProvider.unknown, providerOf(""));
}
