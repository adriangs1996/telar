//! One command of the list. A row is one line: a status glyph, the command
//! in the terminal face and, in the space the command leaves, its directory
//! and time. The selected row opens into a card: the complete command
//! wrapped, its facts on a line of their own and the secondary actions.
//! Nothing is cut without a mark: `…` ends a line that did not fit, `↵` one
//! that continues below, and a card past its line limit says how much the
//! inspector still holds.
const cellgrid = @import("cellgrid");
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const data = @import("model");
const Canvas = @import("../Canvas.zig");
const ChromeMetrics = @import("../ChromeMetrics.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Target = @import("../interaction/Target.zig");
const labels = @import("history_labels.zig");
const Label = @import("../Label.zig");
const HistoryHint = @import("HistoryHint.zig");
const WrappedLines = @import("WrappedLines.zig");
const key_label = @import("key_label.zig");
const Row = @This();

/// Logical size of the provider mark, the sprite page's cell.
pub const mark_size: f32 = 16;
/// Wrapped lines an open card shows before it points at the inspector.
pub const max_lines: u16 = 10;
/// Lines counted past the limit; a longer command reports this many or more.
const more_bound: u16 = 64;
/// The narrowest command column that still gives room to the facts.
const min_command: f32 = 160;

/// The row's rectangle; an opening card's grows from `row_height`.
bounds: Rect,
projection: *const client.Projection,
index: u16,
selected: bool = false,
/// The height of a closed row, and of an open card's first line.
row_height: f32,
/// How open the card is: 0 paints a one-line row, 1 the whole card.
open: f32 = 0,
/// Opacity of the selection surface: full on the selected row, fading on
/// the one the selection left.
highlight: f32 = 0,
line_limit: u16 = max_lines,
/// The time column: the clock under a day heading, the date when searching.
time: enum { clock, date } = .clock,
/// Directory and pane scopes make the directory redundant.
show_cwd: bool = true,

/// Selecting a row never pastes or runs it. The delivered page revision guards
/// asynchronous replacements. Example: `try row.draw(canvas);`
pub fn draw(self: Row, canvas: *Canvas) !void {
    if (self.bounds.width <= 0 or self.bounds.height <= 0) {
        return;
    }

    const history = self.projection.history;
    const command = self.shownCommand();
    const palette = canvas.theme.palette;
    const px = canvas.chrome;
    const frame = self.inset(canvas);
    var hovered = false;
    if (canvas.widgets) |state| {
        const target = (Target{
            .id = .{ .generation = self.projection.prompt.?.generation },
            .bounds = frame,
            .action = .{ .history = .{ .select = .{ .index = self.index, .revision = history.version() } } },
            .layer = 1,
            .focusable = false,
            .enabled = history.phase == .ready,
        }).labelled(command);
        const id = try state.dispatcher.add(target);
        hovered = if (state.dispatcher.hovered) |hover| hover.eql(id) else false;
    }

    if (self.highlight > 0) {
        try canvas.fillRoundedAt(frame, .{ .color = palette.surface0, .radius = px.px(8), .alpha = self.highlight });
        try canvas.fillRoundedAt(frame, .{ .color = palette.accent, .radius = px.px(8), .alpha = 0.08 * self.highlight });
        try canvas.ringAt(frame, .{ .color = palette.accent, .width = px.px(1), .radius = px.px(8), .alpha = 0.28 * self.highlight });
    } else if (hovered) {
        try canvas.fillRoundedAt(frame, .{ .color = palette.surface0, .radius = px.px(8), .alpha = 0.6 });
    }

    const first = canvas.quads.items().len;
    const zone = self.lineZone(canvas, frame);
    const status = statusOf(&history.slice()[self.index], palette);
    _ = try canvas.textAt(.{
        .x = frame.x + px.px(10),
        .y = zone.y,
        .width = px.px(20),
        .height = zone.height,
    }, .{
        .text = status.glyph,
        .color = status.color,
    });

    var facts: Facts = .{};
    if (self.open > 0) {
        try self.measureFacts(canvas, &facts, .{ .width = zone.width, .needed = null });
        try self.paintFacts(canvas, &facts, zone);
        try self.card(canvas, .{ .frame = frame, .text = textColumn(zone, facts.reserved(px)), .command = command });
    } else {
        const line = firstLine(command);
        const needed = try canvas.measure(.{ .text = line.text });
        try self.measureFacts(canvas, &facts, .{ .width = zone.width, .needed = needed });
        try self.paintFacts(canvas, &facts, zone);
        var highlight: MatchHighlight = .{ .query = self.query() };
        try commandLine(canvas, .{ .bounds = textColumn(zone, facts.reserved(px)), .text = line.text, .continues = line.continues }, &highlight);
    }

    canvas.quads.clipFrom(first, frame);
}

/// The height of this row's card fully open at the row's width, counting
/// the same wrapped lines `draw` paints.
/// Example: `const height = try row.cardHeight(canvas);`
pub fn cardHeight(self: Row, canvas: *Canvas) !f32 {
    const px = canvas.chrome;
    const zone = self.lineZone(canvas, self.inset(canvas));
    var facts: Facts = .{};
    try self.measureFacts(canvas, &facts, .{ .width = zone.width, .needed = null });
    const column = textColumn(zone, facts.reserved(px));
    const wrapped = wrap(self.shownCommand(), columnsOf(canvas, column.width), self.line_limit);
    const cell: f32 = @floatFromInt(canvas.metrics.cell_height);
    return px.px(2) + topInset(zone, cell) + @as(f32, @floatFromInt(wrapped.shown)) * cell + px.px(4) + metaHeight(canvas) + px.px(8);
}

/// The built-in provider a history entry's manifest name denotes.
/// Example: `if (canvas.providerMark(HistoryRow.providerOf(entry.providerSlice()))) |mark| ...`
pub fn providerOf(name: []const u8) core.AgentProvider {
    return core.builtinProvider(name) orelse .unknown;
}

// The complete command when the page owns it, its bounded preview otherwise;
// the card says which one it shows.
fn shownCommand(self: Row) []const u8 {
    const history = self.projection.history;
    return history.ownedCommand(self.index) orelse history.slice()[self.index].commandSlice();
}

fn query(self: Row) []const u8 {
    const prompt = &self.projection.prompt.?;
    return client.history_palette.historyFilters(prompt, prompt.field.text()).query;
}

// Rows keep a hairline between each other and an inset from the list's edges.
fn inset(self: Row, canvas: *const Canvas) Rect {
    const px = canvas.chrome;
    return .{
        .x = self.bounds.x + px.px(8),
        .y = self.bounds.y + px.px(1),
        .width = @max(0, self.bounds.width - px.px(16)),
        .height = @max(0, self.bounds.height - px.px(2)),
    };
}

// The first line: from after the status glyph to the row's right inset.
fn lineZone(self: Row, canvas: *const Canvas, bounds: Rect) Rect {
    const px = canvas.chrome;
    const x = bounds.x + px.px(40);
    return .{
        .x = x,
        .y = bounds.y,
        .width = @max(0, bounds.x + bounds.width - px.px(12) - x),
        .height = @max(0, self.row_height - px.px(2)),
    };
}

fn textColumn(area: Rect, reserved: f32) Rect {
    return .{
        .x = area.x,
        .y = area.y,
        .width = @max(0, area.width - reserved),
        .height = area.height,
    };
}

fn topInset(area: Rect, cell: f32) f32 {
    return @max(0, @floor((area.height - cell) / 2));
}

fn metaHeight(canvas: *const Canvas) f32 {
    return @max(canvas.chrome.px(22), canvas.chrome.rowHeight(.small) + canvas.chrome.px(6));
}

fn columnsOf(canvas: *const Canvas, width: f32) u16 {
    const cell: f32 = @floatFromInt(@max(1, canvas.metrics.cell_width));
    return @intFromFloat(@min(65535, @max(0, @floor(width / cell))));
}

// ---------------------------------------------------------------------------
// The facts beside the first line
// ---------------------------------------------------------------------------

const Token = struct {
    kind: enum { mark, cwd, time },
    label: Label = .{ .text = "" },
    width: f32,
};

/// The facts of the first line with the storage their labels borrow, so the
/// value stays where it was measured until it is painted.
const Facts = struct {
    tokens: [3]Token = undefined,
    count: usize = 0,
    width: f32 = 0,
    time_storage: [32]u8 = undefined,
    path_storage: [labels.path_bytes]u8 = undefined,

    // What the command column gives up: the facts and the gap before them.
    fn reserved(self: *const Facts, px: ChromeMetrics) f32 {
        return if (self.count == 0) 0 else self.width + px.px(14);
    }

    fn remove(self: *Facts, index: usize, gap: f32) void {
        self.width -= self.tokens[index].width + gap;
        std.mem.copyForwards(Token, self.tokens[index .. self.count - 1], self.tokens[index + 1 .. self.count]);
        self.count -= 1;
    }
};

// The command comes first. The directory shows only in the space a command
// of `needed` pixels leaves, and never on a card, whose facts line has it.
// A narrow row then drops the time, and the provider mark last.
fn measureFacts(self: Row, canvas: *Canvas, facts: *Facts, input: struct { width: f32, needed: ?f32 }) !void {
    const history = self.projection.history;
    const item = &history.slice()[self.index];
    const palette = canvas.theme.palette;
    const px = canvas.chrome;
    const gap = px.px(14);
    if (item.author == .agent) {
        facts.tokens[facts.count] = .{ .kind = .mark, .width = @round(px.px(mark_size)) };
        facts.count += 1;
    }
    if (input.needed != null and self.show_cwd and item.cwd_len != 0) {
        const label: Label = .{ .text = labels.compactPath(item.cwdSlice(), &facts.path_storage), .color = palette.subtext0, .alpha = 0.8, .face = .sans, .size = .small };
        facts.tokens[facts.count] = .{ .kind = .cwd, .label = label, .width = try canvas.measure(label) };
        facts.count += 1;
    }
    if (item.started_at_ms >= 0) {
        const text = switch (self.time) {
            .clock => labels.clock(item.started_at_ms, history.utc_offset_min, &facts.time_storage),
            .date => labels.dateLabel(item.started_at_ms, history.now_ms, history.utc_offset_min, &facts.time_storage),
        };
        const label: Label = .{ .text = text, .color = palette.subtext0, .face = .sans, .size = .small };
        facts.tokens[facts.count] = .{ .kind = .time, .label = label, .width = try canvas.measure(label) };
        facts.count += 1;
    }

    for (facts.tokens[0..facts.count]) |token| {
        facts.width += token.width + gap;
    }

    if (input.needed) |needed| {
        for (facts.tokens[0..facts.count], 0..) |token, index| {
            if (token.kind == .cwd and needed + facts.width > input.width) {
                facts.remove(index, gap);
                break;
            }
        }
    }

    while (facts.count > 0 and facts.width - gap > input.width - px.px(min_command)) {
        facts.remove(facts.count - 1, gap);
    }

    facts.width = @max(0, facts.width - gap);
}

fn paintFacts(self: Row, canvas: *Canvas, facts: *const Facts, area: Rect) !void {
    const gap = canvas.chrome.px(14);
    var x = area.x + area.width - facts.width;
    for (facts.tokens[0..facts.count]) |token| {
        switch (token.kind) {
            .mark => try self.mark(canvas, .{
                .x = x,
                .y = area.y + @floor((area.height - token.width) / 2),
                .width = token.width,
                .height = token.width,
            }),
            .cwd, .time => _ = try canvas.textAt(.{
                .x = x,
                .y = area.y,
                .width = token.width,
                .height = area.height,
            }, token.label),
        }

        x += token.width + gap;
    }
}

// A built-in provider shows its mark from the sprite page; any other agent
// shows the first letter of its manifest name on a small chip.
fn mark(self: Row, canvas: *Canvas, box: Rect) !void {
    const item = &self.projection.history.slice()[self.index];
    const palette = canvas.theme.palette;
    const provider = providerOf(item.providerSlice());
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
    const name = item.providerSlice();
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

// ---------------------------------------------------------------------------
// The command
// ---------------------------------------------------------------------------

/// The query's characters still to find, carried across a card's lines.
const MatchHighlight = struct {
    query: []const u8,
    matched: usize = 0,
};

const FirstLine = struct {
    text: []const u8,
    /// The command goes on below this line.
    continues: bool,
};

fn firstLine(text: []const u8) FirstLine {
    const end = std.mem.indexOfAny(u8, text, "\r\n") orelse return .{ .text = text, .continues = false };
    return .{ .text = text[0..end], .continues = true };
}

// One line of the command with the query's characters in the accent. A line
// that does not fit ends in `…`; one the command continues below, in `↵`.
fn commandLine(canvas: *Canvas, value: struct { bounds: Rect, text: []const u8, continues: bool = false }, highlight: *MatchHighlight) !void {
    const cell: f32 = @floatFromInt(@max(1, canvas.metrics.cell_width));
    const columns = @floor(value.bounds.width / cell);
    const needed = try canvas.measure(.{ .text = value.text });
    const overflows = needed > value.bounds.width;
    var bounds = value.bounds;
    if ((overflows or value.continues) and columns >= 2) {
        bounds.width = if (overflows) (columns - 1) * cell else @min(needed + cell, (columns - 1) * cell);
        _ = try canvas.textAt(.{
            .x = value.bounds.x + bounds.width,
            .y = value.bounds.y,
            .width = cell,
            .height = value.bounds.height,
        }, .{
            .text = if (overflows) "…" else "↵",
            .color = canvas.theme.palette.subtext0,
        });
    }

    _ = try canvas.textAt(bounds, .{
        .text = value.text,
        .color = canvas.theme.palette.text,
    });
    var iterator: cellgrid.GraphemeIterator = .{ .bytes = value.text };
    var column: u16 = 0;
    const query_text = highlight.query;
    while (@as(f32, @floatFromInt(column)) * cell < bounds.width and highlight.matched < query_text.len) {
        const cluster = iterator.next() orelse break;
        const width = @as(f32, @floatFromInt(cluster.width)) * cell;
        const x = @as(f32, @floatFromInt(column)) * cell;
        if (x + width > bounds.width) {
            break;
        }

        if (cluster.bytes.len <= query_text.len - highlight.matched and std.ascii.eqlIgnoreCase(cluster.bytes, query_text[highlight.matched..][0..cluster.bytes.len])) {
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
            highlight.matched += cluster.bytes.len;
        }

        column += cluster.width;
    }
}

// ---------------------------------------------------------------------------
// The open card
// ---------------------------------------------------------------------------

const Wrapped = struct {
    /// Lines the card paints.
    shown: u16,
    /// Lines past the limit, counted up to `more_bound`.
    more: u16,
};

// Counts wrapped lines without walking a long command to its end: the
// card needs the lines it shows and a bounded count of the rest.
fn wrap(text: []const u8, columns: u16, limit: u16) Wrapped {
    var lines: WrappedLines = .{ .text = text, .width = columns, .words = true };
    var total: u16 = 0;
    while (total < limit +| more_bound and lines.next() != null) {
        total += 1;
    }

    const shown = @min(total, limit);
    return .{ .shown = shown, .more = total - shown };
}

fn card(self: Row, canvas: *Canvas, value: struct { frame: Rect, text: Rect, command: []const u8 }) !void {
    const px = canvas.chrome;
    const cell: f32 = @floatFromInt(canvas.metrics.cell_height);
    const columns = columnsOf(canvas, value.text.width);
    const wrapped = wrap(value.command, columns, self.line_limit);
    var lines: WrappedLines = .{ .text = value.command, .width = columns, .words = true };
    var highlight: MatchHighlight = .{ .query = self.query() };
    var y = value.text.y + topInset(value.text, cell);
    var painted: u16 = 0;
    while (painted < wrapped.shown) : (painted += 1) {
        const line = lines.next() orelse break;
        try commandLine(canvas, .{ .bounds = .{ .x = value.text.x, .y = y, .width = value.text.width, .height = cell }, .text = line }, &highlight);
        y += cell;
    }

    try self.meta(canvas, .{
        .x = value.text.x,
        .y = y + px.px(4),
        .width = @max(0, value.frame.x + value.frame.width - px.px(8) - value.text.x),
        .height = metaHeight(canvas),
    }, wrapped);
}

const mac_actions = [_]Action{
    .{ .key = "⌘C", .word = "copy", .kind = .copy },
    .{ .key = "⌘⌫", .word = "delete", .kind = .remove },
    .{ .key = "⌥↩", .word = "go to pane", .kind = .visit_pane },
};
const pc_actions = [_]Action{
    .{ .key = "Ctrl+C", .word = "copy", .kind = .copy },
    .{ .key = "Ctrl+D", .word = "delete", .kind = .remove },
    .{ .key = "Alt+Enter", .word = "go to pane", .kind = .visit_pane },
};

const Action = struct {
    key: []const u8,
    word: []const u8,
    kind: enum { copy, remove, visit_pane },
};

// The card's last line: what the row above left out (directory, outcome,
// duration, age, author) on the left, and on the right the actions that
// only make sense for a selection. Actions drop first on a narrow card.
fn meta(self: Row, canvas: *Canvas, area: Rect, wrapped: Wrapped) !void {
    if (area.width <= 0 or area.height <= 0) {
        return;
    }

    const history = self.projection.history;
    const item = &history.slice()[self.index];
    const px = canvas.chrome;
    const ready = history.phase == .ready;
    const generation = self.projection.prompt.?.generation;
    const pane_open = self.projection.model.panes.findConst(item.pane_id) != null;
    // The actions keep their reading order and drop from the end.
    const all = if (key_label.host_style == .mac) &mac_actions else &pc_actions;
    var hints: [mac_actions.len]HistoryHint = undefined;
    var count: usize = 0;
    var total: f32 = 0;
    for (all) |action| {
        // A card the selection left is closing; its actions went with it.
        if (!self.selected or (action.kind == .visit_pane and !pane_open)) {
            continue;
        }

        var hint: HistoryHint = .{
            .bounds = .{ .x = 0, .y = area.y, .width = 0, .height = area.height },
            .key = action.key,
            .word = action.word,
            .action = switch (action.kind) {
                .copy => .{ .history = .copy },
                .remove => .{ .history = .remove },
                .visit_pane => .{ .history = .visit_pane },
            },
            .enabled = ready,
            .generation = generation,
            .namespace = .card,
        };
        hint.bounds.width = try hint.width(canvas);
        if (area.width - total - hint.bounds.width < px.px(min_command)) {
            break;
        }

        total += hint.bounds.width + px.px(2);
        hints[count] = hint;
        count += 1;
    }

    var x = area.x + area.width - total;
    for (hints[0..count]) |value| {
        var hint = value;
        hint.bounds.x = x;
        try hint.draw(canvas);
        x += hint.bounds.width + px.px(2);
    }

    const right = area.x + area.width - total;
    try self.metaFacts(canvas, .{ .x = area.x, .y = area.y, .width = @max(0, right - px.px(10) - area.x), .height = area.height }, wrapped);
}

fn metaFacts(self: Row, canvas: *Canvas, area: Rect, wrapped: Wrapped) !void {
    const history = self.projection.history;
    const item = &history.slice()[self.index];
    const palette = canvas.theme.palette;
    const gap = canvas.chrome.px(14);
    var notice_storage: [64]u8 = undefined;
    var path_storage: [labels.path_bytes]u8 = undefined;
    var exit_storage: [24]u8 = undefined;
    var duration_storage: [32]u8 = undefined;
    var age_storage: [32]u8 = undefined;
    var tokens: [6]Label = undefined;
    var count: usize = 0;
    const inspect_key = if (key_label.host_style == .mac) "⌃O" else "Ctrl+O";
    if (item.captured_truncated) {
        tokens[count] = .{ .text = "capture cut short, cannot paste", .color = palette.yellow };
        count += 1;
    } else if (history.ownedCommand(self.index) == null) {
        tokens[count] = .{ .text = "loading the complete command…", .color = palette.subtext0 };
        count += 1;
    } else if (wrapped.more != 0) {
        tokens[count] = .{ .text = std.fmt.bufPrint(&notice_storage, "+{d}{s} more lines  ·  {s} shows all", .{ wrapped.more, if (wrapped.more == more_bound) "+" else "", inspect_key }) catch "more lines", .color = palette.accent };
        count += 1;
    }
    if (self.show_cwd and item.cwd_len != 0) {
        tokens[count] = .{ .text = labels.compactPath(item.cwdSlice(), &path_storage), .color = palette.subtext0 };
        count += 1;
    }

    switch (item.status) {
        .running => {
            tokens[count] = .{ .text = "running", .color = palette.teal };
            count += 1;
        },
        .interrupted => {
            tokens[count] = .{ .text = "stopped", .color = palette.yellow };
            count += 1;
        },
        .completed => if (item.exit_code) |code| {
            if (code != 0) {
                tokens[count] = .{ .text = std.fmt.bufPrint(&exit_storage, "exit {d}", .{code}) catch "exit", .color = palette.red };
                count += 1;
            }
        },
    }

    if (item.status != .running) {
        tokens[count] = .{ .text = labels.duration(item.duration_ns, &duration_storage), .color = palette.subtext0 };
        count += 1;
    }
    if (item.started_at_ms >= 0) {
        tokens[count] = .{ .text = labels.age(history.now_ms -| item.started_at_ms, &age_storage), .color = palette.subtext0 };
        count += 1;
    }
    if (item.author == .agent) {
        tokens[count] = .{ .text = if (item.provider_len != 0) item.providerSlice() else "agent", .color = palette.subtext0 };
        count += 1;
    }

    var x = area.x;
    const limit = area.x + area.width;
    for (tokens[0..count]) |token| {
        var label = token;
        label.face = .sans;
        label.size = .small;
        const width = try canvas.measure(label);
        if (x + width > limit) {
            break;
        }

        _ = try canvas.textAt(.{ .x = x, .y = area.y, .width = width, .height = area.height }, label);
        x += width + gap;
    }
}

const Status = struct {
    glyph: []const u8,
    color: cellgrid.Color,
};

// One color per meaning: success stays quiet, failure and interruption speak.
fn statusOf(item: anytype, palette: anytype) Status {
    return switch (item.status) {
        .running => .{ .glyph = "◌", .color = palette.teal },
        .interrupted => .{ .glyph = "■", .color = palette.yellow },
        .completed => if (item.exit_code) |code| (if (code == 0) Status{ .glyph = "·", .color = palette.overlay0 } else Status{ .glyph = "✕", .color = palette.red }) else Status{ .glyph = "·", .color = palette.subtext0 },
    };
}

test "manifest names select the built-in provider mark or none" {
    try std.testing.expectEqual(core.AgentProvider.claude, providerOf("claude"));
    try std.testing.expectEqual(core.AgentProvider.codex, providerOf("codex"));
    try std.testing.expectEqual(core.AgentProvider.pi, providerOf("pi"));
    try std.testing.expectEqual(core.AgentProvider.cursor, providerOf("cursor"));
    try std.testing.expectEqual(core.AgentProvider.opencode, providerOf("opencode"));
    try std.testing.expectEqual(core.AgentProvider.unknown, providerOf("aider"));
    try std.testing.expectEqual(core.AgentProvider.unknown, providerOf(""));
}

test "a card counts the lines it shows and a bounded rest" {
    try std.testing.expectEqual(Wrapped{ .shown = 1, .more = 0 }, wrap("ls", 80, 10));
    try std.testing.expectEqual(Wrapped{ .shown = 2, .more = 0 }, wrap("a" ** 100, 80, 10));
    try std.testing.expectEqual(Wrapped{ .shown = 3, .more = 0 }, wrap("for x in a b; do\n  echo $x\ndone", 80, 10));
    try std.testing.expectEqual(Wrapped{ .shown = 2, .more = 3 }, wrap("1\n2\n3\n4\n5", 80, 2));
    try std.testing.expectEqual(Wrapped{ .shown = 4, .more = more_bound }, wrap("x\n" ** 4096, 80, 4));
    try std.testing.expectEqual(Wrapped{ .shown = 0, .more = 0 }, wrap("ls", 0, 10));
}

test "a row shows the first line of a command and marks that it continues" {
    try std.testing.expectEqualDeep(FirstLine{ .text = "zig build", .continues = false }, firstLine("zig build"));
    try std.testing.expectEqualDeep(FirstLine{ .text = "for x in a b; do", .continues = true }, firstLine("for x in a b; do\n  echo $x\ndone"));
    try std.testing.expectEqualDeep(FirstLine{ .text = "", .continues = true }, firstLine("\r\nls"));
}
