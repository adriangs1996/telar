//! Inbox of agent sessions currently owned by the runtime.
//!
//! The widget renders the runtime snapshot directly. It has no task taxonomy,
//! filters, tabs, or task actions. Clicking an agent remains a client-owned
//! navigation action that focuses its pane when that pane is attached.

const std = @import("std");
const core = @import("telar-core");
const widget = @import("context.zig");
const model = @import("sidebar_model.zig");
const ui = @import("../ui.zig");

const schema = core.schema;

pub const Snapshot = model.Snapshot;
pub const SnapshotInput = model.SnapshotInput;
pub const AgentInput = model.AgentInput;
pub const AgentKey = model.AgentKey;

pub const max_provider_marks = model.max_agents;
const rows_per_agent = 3;

pub const State = struct {
    selected_agent: ?AgentKey = null,
    scroll: u16 = 0,
    total_rows: u16 = 0,

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
    list_area: ui.Rect = .{},
    cursor: ?widget.Cursor = null,

    pub const ProviderMark = struct {
        area: ui.Rect,
        provider: schema.AgentProvider,
    };

    fn addProviderMark(semantic: *Semantic, mark: ProviderMark) void {
        if (semantic.provider_mark_count == semantic.provider_marks.len) return;
        semantic.provider_marks[semantic.provider_mark_count] = mark;
        semantic.provider_mark_count += 1;
    }
};

pub const Input = struct {
    area: ui.Rect,
    snapshot: *const Snapshot,
    state: *State,
    transparent: bool,
    animation_frame: u8 = 0,
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
    context.buffer.fill(area, " ", .{ .fg = context.palette.text, .bg = background });
    drawRightSeparator(context, area, background);
    if (area.w > 10) _ = context.buffer.writeText(area, area.x + 2, area.y, "agents", .{
        .fg = context.palette.subtext0,
        .bg = background,
        .flags = .{ .bold = true },
    });
    if (area.w < 24 or area.h < 6) return;

    const inside: ui.Rect = .{
        .x = area.x + 1,
        .y = area.y + 1,
        .w = area.w - 2,
        .h = area.h - 2,
    };
    drawHeader(context, input.snapshot, inside, background);
    _ = drawRule(context, area, inside.y + 1, background);
    semantic.list_area = .{
        .x = inside.x,
        .y = inside.y + 2,
        .w = inside.w,
        .h = inside.h - 2,
    };
    drawAgents(context, input, semantic);
}

fn drawHeader(
    context: *widget.Context,
    snapshot: *const Snapshot,
    area: ui.Rect,
    background: ui.Color,
) void {
    const row: ui.Rect = .{ .x = area.x, .y = area.y, .w = area.w, .h = 1 };
    context.buffer.fill(row, " ", .{ .bg = background });
    _ = context.buffer.writeText(row, row.x + 1, row.y, "inbox", .{
        .fg = context.palette.text,
        .bg = background,
        .flags = .{ .bold = true },
    });
    var count_buffer: [16]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buffer, "{d} open", .{snapshot.count}) catch "";
    _ = context.buffer.writeRight(.{ .x = row.x, .y = row.y, .w = row.w -| 1, .h = 1 }, row.y, count, .{
        .fg = context.palette.overlay0,
        .bg = background,
    });
}

fn drawAgents(context: *widget.Context, input: Input, semantic: *Semantic) void {
    const area = semantic.list_area;
    const background = cellBackground(context, input.transparent);
    context.buffer.fill(area, " ", .{ .bg = background });

    const total: u16 = @intCast(@as(usize, input.snapshot.count) * rows_per_agent);
    input.state.total_rows = total;
    input.state.scroll = @min(input.state.scroll, total -| area.h);
    if (input.snapshot.count == 0) {
        drawEmpty(context, area, background);
        return;
    }

    var line: u16 = 0;
    while (line < area.h) : (line += 1) {
        const row_index = input.state.scroll + line;
        if (row_index >= total) break;
        const agent_index: usize = row_index / rows_per_agent;
        const card_line: u2 = @intCast(row_index % rows_per_agent);
        drawAgentLine(
            context,
            input,
            semantic,
            area.y + line,
            &input.snapshot.slice()[agent_index],
            card_line,
            background,
        );
    }
    drawScrollbar(context, input.state, area, total, background);
}

fn drawAgentLine(
    context: *widget.Context,
    input: Input,
    semantic: *Semantic,
    y: u16,
    agent: *const model.Agent,
    line: u2,
    background: ui.Color,
) void {
    const action: widget.Action = .{ .sidebar_select_agent = agent.key };
    const selected = if (input.state.selected_agent) |key| std.meta.eql(key, agent.key) else false;
    const hovered = context.isHovered(action);
    const row_bg = if (selected)
        context.palette.surface0
    else if (hovered)
        context.palette.surface1
    else
        background;
    const row: ui.Rect = .{
        .x = semantic.list_area.x,
        .y = y,
        .w = semantic.list_area.w -| 1,
        .h = 1,
    };
    context.buffer.fill(row, " ", .{ .bg = row_bg });
    if (selected) {
        _ = context.buffer.writeText(row, row.x, y, "┃", .{
            .fg = context.palette.accent,
            .bg = row_bg,
        });
        if (line == 0 and y + 1 < semantic.list_area.y + semantic.list_area.h)
            semantic.selected_card = .{
                .x = row.x,
                .y = y,
                .w = row.w,
                .h = @min(rows_per_agent, semantic.list_area.y + semantic.list_area.h - y),
            };
    }

    const body: ui.Rect = .{ .x = row.x + 2, .y = y, .w = row.w -| 3, .h = 1 };
    if (line == 0) {
        drawAgentTitle(context, input, semantic, body, agent, row_bg);
    } else if (line == 1) {
        drawAgentPane(context, body, agent, row_bg);
    }
    context.hits.add(row, action);
}

fn drawAgentTitle(
    context: *widget.Context,
    input: Input,
    semantic: *Semantic,
    area: ui.Rect,
    agent: *const model.Agent,
    background: ui.Color,
) void {
    if (area.w == 0) return;
    const mark_area: ui.Rect = .{ .x = area.x, .y = area.y, .w = 2, .h = 2 };
    if (input.transparent and (agent.provider == .claude or agent.provider == .codex)) {
        semantic.addProviderMark(.{ .area = mark_area, .provider = agent.provider });
    } else {
        _ = context.buffer.writeText(area, area.x, area.y, providerGlyph(agent.provider), .{
            .fg = context.palette.accent,
            .bg = background,
        });
    }
    const status_width = statusWidth(agent.status);
    _ = context.buffer.writeTruncated(
        area,
        area.x + 3,
        area.y,
        providerLabel(agent.provider),
        area.w -| status_width -| 3,
        .{ .fg = context.palette.text, .bg = background, .flags = .{ .bold = true } },
    );
    drawStatus(context, area, agent.status, input.animation_frame, background);
}

fn drawAgentPane(
    context: *widget.Context,
    area: ui.Rect,
    agent: *const model.Agent,
    background: ui.Color,
) void {
    var pane_buffer: [32]u8 = undefined;
    const pane = std.fmt.bufPrint(&pane_buffer, "pane {d}", .{schema.id.raw(agent.key.pane_id)}) catch "";
    _ = context.buffer.writeTruncated(area, area.x + 3, area.y, pane, area.w -| 3, .{
        .fg = context.palette.overlay0,
        .bg = background,
    });
}

fn drawStatus(
    context: *widget.Context,
    area: ui.Rect,
    status: schema.AgentStatus,
    animation_frame: u8,
    background: ui.Color,
) void {
    const width = statusWidth(status);
    if (width > area.w) return;
    var x = area.x + area.w - width;
    x += context.buffer.writeText(area, x, area.y, statusGlyph(status, animation_frame), .{
        .fg = statusColor(context, status),
        .bg = background,
    });
    x += context.buffer.writeText(area, x, area.y, " ", .{ .bg = background });
    _ = context.buffer.writeText(area, x, area.y, statusLabel(status), .{
        .fg = statusColor(context, status),
        .bg = background,
        .flags = .{ .bold = status == .blocked or status == .failed },
    });
}

fn statusWidth(status: schema.AgentStatus) u16 {
    return ui.measure(statusLabel(status)) + 2;
}

fn statusGlyph(status: schema.AgentStatus, animation_frame: u8) []const u8 {
    const working = [_][]const u8{ "◐", "◓", "◑", "◒" };
    return switch (status) {
        .unknown => "?",
        .working => working[animation_frame % working.len],
        .blocked => "!",
        .ready => "✓",
        .failed => "×",
    };
}

fn providerLabel(provider: schema.AgentProvider) []const u8 {
    return switch (provider) {
        .unknown => "Agent",
        .claude => "Claude Code",
        .codex => "Codex",
    };
}

fn providerGlyph(provider: schema.AgentProvider) []const u8 {
    return switch (provider) {
        .unknown => "?",
        .claude => "✳",
        .codex => "◆",
    };
}

fn statusLabel(status: schema.AgentStatus) []const u8 {
    return switch (status) {
        .unknown => "unknown",
        .working => "working",
        .blocked => "needs input",
        .ready => "ready",
        .failed => "failed",
    };
}

fn statusColor(context: *const widget.Context, status: schema.AgentStatus) ui.Color {
    return switch (status) {
        .unknown => context.palette.overlay0,
        .working => context.palette.accent,
        .blocked => context.palette.yellow,
        .ready => context.palette.green,
        .failed => context.palette.red,
    };
}

fn drawEmpty(context: *widget.Context, area: ui.Rect, background: ui.Color) void {
    if (area.h < 2) return;
    _ = context.buffer.writeTruncated(area, area.x + 2, area.y + 1, "No open agents", area.w -| 4, .{
        .fg = context.palette.subtext0,
        .bg = background,
        .flags = .{ .bold = true },
    });
    if (area.h >= 4) _ = context.buffer.writeTruncated(
        area,
        area.x + 2,
        area.y + 3,
        "Agent sessions will appear here.",
        area.w -| 4,
        .{ .fg = context.palette.overlay0, .bg = background },
    );
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
        _ = context.buffer.writeText(area, area.x, area.y + line, if (on_thumb) "█" else "│", .{
            .fg = if (on_thumb) context.palette.overlay1 else context.palette.surface1,
            .bg = background,
        });
        const target: u16 = @intCast(@as(u32, line) * max_scroll / area.h);
        context.hits.add(.{ .x = area.x, .y = area.y + line, .w = 1, .h = 1 }, .{ .sidebar_scroll_to = target });
    }
}

fn drawRule(context: *widget.Context, area: ui.Rect, y: u16, background: ui.Color) u16 {
    const style: ui.Style = .{ .fg = context.palette.surface1, .bg = background };
    var x = area.x + 1;
    while (x < area.x + area.w - 1) : (x += 1)
        _ = context.buffer.writeText(area, x, y, "─", style);
    return y + 1;
}

fn drawRightSeparator(context: *widget.Context, area: ui.Rect, background: ui.Color) void {
    if (area.w == 0) return;
    const x = area.x + area.w - 1;
    var y = area.y;
    while (y < area.y + area.h) : (y += 1) {
        _ = context.buffer.writeText(area, x, y, "│", .{
            .fg = context.palette.surface1,
            .bg = background,
        });
    }
}

fn cellBackground(context: *const widget.Context, transparent: bool) ui.Color {
    return if (transparent) .default else context.palette.panel_bg;
}

test "empty snapshot renders only the agent inbox chrome" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 48, 20);
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
    try std.testing.expect(output.cursor == null);
    try std.testing.expectEqualStrings("g", buffer.at(3, 0).?.text());
    try std.testing.expectEqualStrings("i", buffer.at(2, 1).?.text());
    try std.testing.expect(hits.at(3, 1) == null);
}

test "agent snapshot renders compact selectable rows and status" {
    var snapshot: Snapshot = .{};
    const agents = [_]AgentInput{.{
        .key = .{ .pane_id = @enumFromInt(41), .pane_generation = 3 },
        .provider = .codex,
        .status = .blocked,
    }};
    _ = try snapshot.replace(.{ .revision = 1, .agents = &agents });
    var buffer = try ui.Buffer.init(std.testing.allocator, 48, 20);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var state: State = .{ .selected_agent = agents[0].key };
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
    try std.testing.expectEqual(@as(u16, 3), output.selected_card.?.h);
    try std.testing.expectEqualDeep(
        widget.Action{ .sidebar_select_agent = agents[0].key },
        hits.at(4, output.selected_card.?.y).?,
    );
    try std.testing.expectEqualStrings("p", buffer.at(6, output.selected_card.?.y + 1).?.text());
}

test "transparent Codex row publishes an official provider mark" {
    var snapshot: Snapshot = .{};
    const agents = [_]AgentInput{.{
        .key = .{ .pane_id = @enumFromInt(41), .pane_generation = 3 },
        .provider = .codex,
        .status = .ready,
    }};
    _ = try snapshot.replace(.{ .revision = 1, .agents = &agents });
    var buffer = try ui.Buffer.init(std.testing.allocator, 48, 20);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var state: State = .{};
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
        .transparent = true,
    });
    try std.testing.expectEqual(@as(u8, 1), output.provider_mark_count);
    try std.testing.expectEqual(schema.AgentProvider.codex, output.provider_marks[0].provider);
    try std.testing.expectEqual(ui.Rect{ .x = 3, .y = 3, .w = 2, .h = 2 }, output.provider_marks[0].area);
}

test "hover covers the complete three-row agent card" {
    var snapshot: Snapshot = .{};
    const agent: AgentInput = .{
        .key = .{ .pane_id = @enumFromInt(41), .pane_generation = 3 },
        .provider = .codex,
        .status = .working,
    };
    _ = try snapshot.replace(.{ .revision = 1, .agents = &.{agent} });
    var buffer = try ui.Buffer.init(std.testing.allocator, 48, 20);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var state: State = .{};
    const palette = @import("../theme.zig").default_theme.palette;
    const action: widget.Action = .{ .sidebar_select_agent = agent.key };
    var context: widget.Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &palette,
        .hovered = action,
    };
    _ = render(&context, .{
        .area = buffer.area(),
        .snapshot = &snapshot,
        .state = &state,
        .transparent = true,
    });

    try std.testing.expectEqualDeep(palette.surface1, buffer.at(10, 3).?.style.bg);
    try std.testing.expectEqualDeep(palette.surface1, buffer.at(10, 5).?.style.bg);
    try std.testing.expectEqualDeep(action, hits.at(10, 5).?);
}

test "working status uses an animated glyph" {
    try std.testing.expect(!std.mem.eql(
        u8,
        statusGlyph(.working, 0),
        statusGlyph(.working, 1),
    ));
    try std.testing.expectEqualStrings("✓", statusGlyph(.ready, 0));
    try std.testing.expectEqualStrings("!", statusGlyph(.blocked, 0));
}
