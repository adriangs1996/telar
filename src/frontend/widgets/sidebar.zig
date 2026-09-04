//! Inbox of agent sessions currently owned by the runtime.
//!
//! The widget renders the runtime snapshot directly. It has no task taxonomy,
//! filters, tabs, or task actions. Clicking an agent remains a client-owned
//! navigation action that focuses its pane when that pane is attached.

const std = @import("std");
const core = @import("telar-core");
const widget = @import("context.zig");
const agents = @import("../agents/root.zig");
const workspace_capability = @import("../workspace/root.zig");
const ui = @import("../ui/root.zig");

const schema = core.schema;
const multiplexer = workspace_capability.multiplexer;

const Snapshot = agents.Snapshot;
const AgentInput = agents.AgentInput;
const AgentKey = agents.AgentKey;

pub const max_provider_marks = agents.max_agents;
const agent_card_rows = 3;
const agent_row_spacing = 1;
const agent_row_stride = agent_card_rows + agent_row_spacing;
const minions_icon = "\u{2687}";

pub const State = struct {
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
    focused_card: ?ui.Rect = null,
    provider_marks: [max_provider_marks]ProviderMark = undefined,
    provider_mark_count: u8 = 0,
    list_area: ui.Rect = .{},
    cursor: ?widget.Cursor = null,

    pub const ProviderMark = struct {
        area: ui.Rect,
        provider: schema.AgentProvider,
    };

    fn addProviderMark(semantic: *Semantic, mark: ProviderMark) void {
        if (semantic.provider_mark_count == semantic.provider_marks.len) {
            return;
        }
        semantic.provider_marks[semantic.provider_mark_count] = mark;
        semantic.provider_mark_count += 1;
    }
};

pub const Input = struct {
    area: ui.Rect,
    snapshot: *const Snapshot,
    state: *State,
    active_model: ?*const multiplexer.Model = null,
    focused_agent: ?AgentKey = null,
    transparent: bool,
    rounded_focus: bool = false,
    animation_frame: u8 = 0,
};

const AgentLineInput = struct {
    sidebar: Input,
    semantic: *Semantic,
    y: u16,
    agent: *const agents.Agent,
    line: u2,
    background: ui.Color,
};

pub fn render(context: *widget.Context, input: Input) Semantic {
    var semantic: Semantic = .{ .area = input.area };
    renderCells(context, input, &semantic);
    return semantic;
}

fn renderCells(context: *widget.Context, input: Input, semantic: *Semantic) void {
    const area = input.area;
    if (area.isEmpty()) {
        return;
    }
    const background = cellBackground(context, input.transparent);
    context.buffer.fill(area, .{ .glyph = " ", .style = .{ .fg = context.palette.text, .bg = background } });
    drawRightSeparator(context, area, background);
    if (area.w > 10) {
        drawHeader(context, area, background);
    }
    if (area.w < 24 or area.h < 5) {
        return;
    }

    const inside: ui.Rect = .{
        .x = area.x + 1,
        .y = area.y,
        .w = area.w - 2,
        .h = area.h - 1,
    };
    _ = drawRule(context, area, inside.y + 1, background);
    semantic.list_area = .{
        .x = inside.x,
        .y = inside.y + 2,
        .w = inside.w,
        .h = inside.h - 2,
    };
    drawAgents(context, input, semantic);
}

fn drawHeader(context: *widget.Context, area: ui.Rect, background: ui.Color) void {
    const row: ui.Rect = .{ .x = area.x + 2, .y = area.y, .w = area.w -| 3, .h = 1 };
    context.buffer.fill(row, .{ .glyph = " ", .style = .{ .bg = background } });
    _ = context.buffer.writeText(row, .{ .point = .{ .x = row.x, .y = row.y }, .text = minions_icon, .style = .{
        .fg = context.palette.accent,
        .bg = background,
    } });
    _ = context.buffer.writeText(row, .{ .point = .{ .x = row.x + 2, .y = row.y }, .text = "minions", .style = .{
        .fg = context.palette.text,
        .bg = background,
        .flags = .{ .bold = true },
    } });
}

fn drawAgents(context: *widget.Context, input: Input, semantic: *Semantic) void {
    const area = semantic.list_area;
    const background = cellBackground(context, input.transparent);
    context.buffer.fill(area, .{ .glyph = " ", .style = .{ .bg = background } });

    const total: u16 = if (input.snapshot.count == 0)
        0
    else
        @intCast(@as(usize, input.snapshot.count) * agent_row_stride - agent_row_spacing);
    input.state.total_rows = total;
    input.state.scroll = @min(input.state.scroll, total -| area.h);
    if (input.snapshot.count == 0) {
        drawEmpty(context, area, background);
        return;
    }

    var line: u16 = 0;
    while (line < area.h) : (line += 1) {
        const row_index = input.state.scroll + line;
        if (row_index >= total) {
            break;
        }
        const agent_index: usize = row_index / agent_row_stride;
        const card_line: u2 = @intCast(row_index % agent_row_stride);
        if (card_line >= agent_card_rows) {
            continue;
        }

        drawAgentLine(context, .{
            .sidebar = input,
            .semantic = semantic,
            .y = area.y + line,
            .agent = &input.snapshot.slice()[agent_index],
            .line = card_line,
            .background = background,
        });
    }
    drawScrollbar(context, input.state, area, total, background);
}

fn drawAgentLine(context: *widget.Context, line_input: AgentLineInput) void {
    const input = line_input.sidebar;
    const semantic = line_input.semantic;
    const y = line_input.y;
    const agent = line_input.agent;
    const line = line_input.line;
    const background = line_input.background;

    const action: widget.Action = .{ .sidebar_focus_agent = agent.key };
    const focused = if (input.focused_agent) |key| std.meta.eql(key, agent.key) else false;
    const hovered = context.isHovered(action);
    const row_bg = if (focused)
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
    if (focused and line == 0 and y + 1 < semantic.list_area.y + semantic.list_area.h) {
        semantic.focused_card = .{
            .x = row.x,
            .y = y,
            .w = row.w,
            .h = @min(agent_card_rows, semantic.list_area.y + semantic.list_area.h - y),
        };
    }
    context.buffer.fill(row, .{ .glyph = " ", .style = .{ .bg = row_bg } });
    if (focused) {
        const corner_row = if (semantic.focused_card) |card|
            input.rounded_focus and (y == card.y or y + 1 == card.y + card.h)
        else
            false;
        if (corner_row and row.w != 0) {
            context.buffer.fill(.{ .x = row.x, .y = y, .w = 1, .h = 1 }, .{ .glyph = " ", .style = .{} });
            if (row.w > 1) {
                context.buffer.fill(.{
                    .x = row.x + row.w - 1,
                    .y = y,
                    .w = 1,
                    .h = 1,
                }, .{ .glyph = " ", .style = .{} });
            }
        }
        _ = context.buffer.writeText(row, .{ .point = .{ .x = row.x, .y = y }, .text = "┃", .style = .{
            .fg = context.palette.accent,
            .bg = if (corner_row) .default else row_bg,
        } });
    }

    const body: ui.Rect = .{ .x = row.x + 2, .y = y, .w = row.w -| 3, .h = 1 };
    if (line == 0) {
        var title_input = line_input;
        title_input.background = row_bg;
        drawAgentTitle(context, title_input, body);
    } else if (line == 1) {
        drawAgentLocation(context, .{
            .area = body,
            .agent = agent,
            .pane_index = projectedPaneIndex(input, agent),
            .background = row_bg,
        });
    } else {
        drawAgentMeta(context, .{ .area = body, .agent = agent, .background = row_bg });
    }
    context.hits.add(row, action);
}

fn drawAgentTitle(context: *widget.Context, line_input: AgentLineInput, area: ui.Rect) void {
    const input = line_input.sidebar;
    const semantic = line_input.semantic;
    const agent = line_input.agent;
    const background = line_input.background;

    if (area.w == 0) {
        return;
    }
    const mark_area: ui.Rect = .{ .x = area.x, .y = area.y, .w = 2, .h = 2 };
    const icon_style: ui.Style = .{ .fg = context.palette.accent, .bg = background };
    const glyph = agent.iconGlyph();
    const artwork = ui.icons.Icon.forProvider(agent.provider);
    if (glyph.len != 0) {
        _ = context.buffer.writeTruncated(area, .{ .point = .{ .x = area.x, .y = area.y }, .text = glyph, .max_width = 1, .style = icon_style });
    } else if (input.transparent and artwork != null) {
        semantic.addProviderMark(.{ .area = mark_area, .provider = agent.provider });
    } else {
        _ = context.drawIcon(.{ .area = area, .point = .{ .x = area.x, .y = area.y }, .icon = artwork orelse .provider_unknown, .style = icon_style });
    }
    const status_width = statusWidth(agent.status);
    _ = context.buffer.writeTruncated(area, .{ .point = .{ .x = area.x + 3, .y = area.y }, .text = if (agent.sessionTitle().len != 0)
        agent.sessionTitle()
    else
        core.agent_manifest.generic_placeholder, .max_width = area.w -| status_width -| 3, .style = .{ .fg = context.palette.text, .bg = background, .flags = .{ .bold = true } } });
    drawStatus(context, area, agent.status, input.animation_frame, background);
}

const AgentLocationInput = struct {
    area: ui.Rect,
    agent: *const agents.Agent,
    pane_index: u16,
    background: ui.Color,
};

const AgentMetaInput = struct {
    area: ui.Rect,
    agent: *const agents.Agent,
    background: ui.Color,
};

fn drawAgentLocation(context: *widget.Context, input: AgentLocationInput) void {
    var location_buffer: [256]u8 = undefined;
    const workspace_label = input.agent.workspaceLabel();
    const tab = input.agent.tabLabel();
    const location = if (workspace_label.len != 0 and tab.len != 0)
        std.fmt.bufPrint(
            &location_buffer,
            "{s} › {s} › pane {d}",
            .{ workspace_label, tab, input.pane_index },
        ) catch ""
    else if (workspace_label.len != 0)
        std.fmt.bufPrint(
            &location_buffer,
            "{s} › pane {d}",
            .{ workspace_label, input.pane_index },
        ) catch ""
    else if (tab.len != 0)
        std.fmt.bufPrint(
            &location_buffer,
            "{s} › pane {d}",
            .{ tab, input.pane_index },
        ) catch ""
    else
        std.fmt.bufPrint(&location_buffer, "pane {d}", .{input.pane_index}) catch "";
    _ = context.buffer.writeTruncated(input.area, .{ .point = .{ .x = input.area.x + 3, .y = input.area.y }, .text = location, .max_width = input.area.w -| 3, .style = .{
        .fg = context.palette.overlay0,
        .bg = input.background,
    } });
}

fn projectedPaneIndex(input: Input, agent: *const agents.Agent) u16 {
    const active = input.active_model orelse return agent.pane_index;
    const location = active.location orelse return agent.pane_index;
    if (!std.meta.eql(location, agent.location)) {
        return agent.pane_index;
    }

    return active.displayIndex(agent.key.pane_id) orelse agent.pane_index;
}

fn drawAgentMeta(context: *widget.Context, input: AgentMetaInput) void {
    const area = input.area;
    const agent = input.agent;
    const background = input.background;

    if (area.w <= 3) {
        return;
    }
    const style: ui.Style = .{ .fg = context.palette.overlay0, .bg = background };
    const provider = agent.displayName();
    var x = area.x + 3;
    var remaining = area.w - 3;
    const provider_width = ui.measure(provider);
    if (provider_width > remaining or agent.cwdLabel().len == 0) {
        _ = context.buffer.writeTruncated(area, .{ .point = .{ .x = x, .y = area.y }, .text = provider, .max_width = remaining, .style = style });
        return;
    }
    x += context.buffer.writeText(area, .{ .point = .{ .x = x, .y = area.y }, .text = provider, .style = style });
    remaining -|= provider_width;
    const separator = " · ";
    const separator_width = ui.measure(separator);
    if (remaining <= separator_width + 1) {
        return;
    }
    x += context.buffer.writeText(area, .{ .point = .{ .x = x, .y = area.y }, .text = separator, .style = style });
    remaining -= separator_width;
    _ = context.buffer.writeLeftTruncated(area, .{
        .point = .{ .x = x, .y = area.y },
        .text = agent.cwdLabel(),
        .max_width = remaining,
        .style = style,
    });
}

fn drawStatus(context: *widget.Context, area: ui.Rect, status: schema.AgentStatus, animation_frame: u8, background: ui.Color) void {
    const width = statusWidth(status);
    if (width > area.w) {
        return;
    }
    var x = area.x + area.w - width;
    x += context.drawIcon(.{
        .area = area,
        .point = .{ .x = x, .y = area.y },
        .icon = statusIcon(status, animation_frame),
        .style = .{ .fg = statusColor(context, status), .bg = background },
    });
    x += context.buffer.writeText(area, .{ .point = .{ .x = x, .y = area.y }, .text = " ", .style = .{ .bg = background } });
    _ = context.buffer.writeText(area, .{ .point = .{ .x = x, .y = area.y }, .text = statusLabel(status), .style = .{
        .fg = statusColor(context, status),
        .bg = background,
        .flags = .{ .bold = status == .blocked or status == .failed or status == .done },
    } });
}

fn statusWidth(status: schema.AgentStatus) u16 {
    return ui.measure(statusLabel(status)) + 2;
}

fn statusIcon(status: schema.AgentStatus, animation_frame: u8) ui.icons.Icon {
    return switch (status) {
        .unknown => .agent_unknown,
        .working => ui.icons.working(animation_frame),
        .blocked => .agent_blocked,
        .ready => .agent_ready,
        .done => .agent_done,
        .failed => .agent_failed,
    };
}

fn statusLabel(status: schema.AgentStatus) []const u8 {
    return switch (status) {
        .unknown => "unknown",
        .working => "working",
        .blocked => "needs input",
        .ready => "ready",
        .done => "done",
        .failed => "failed",
    };
}

fn statusColor(context: *const widget.Context, status: schema.AgentStatus) ui.Color {
    return switch (status) {
        .unknown => context.palette.overlay0,
        .working => context.palette.accent,
        .blocked => context.palette.yellow,
        .ready => context.palette.green,
        .done => context.palette.teal,
        .failed => context.palette.red,
    };
}

fn drawEmpty(context: *widget.Context, area: ui.Rect, background: ui.Color) void {
    if (area.h < 2) {
        return;
    }
    _ = context.buffer.writeTruncated(area, .{ .point = .{ .x = area.x + 2, .y = area.y + 1 }, .text = "No open agents", .max_width = area.w -| 4, .style = .{
        .fg = context.palette.subtext0,
        .bg = background,
        .flags = .{ .bold = true },
    } });
    if (area.h >= 4) {
        _ = context.buffer.writeTruncated(area, .{ .point = .{ .x = area.x + 2, .y = area.y + 3 }, .text = "Agent sessions will appear here.", .max_width = area.w -| 4, .style = .{ .fg = context.palette.overlay0, .bg = background } });
    }
}

fn drawScrollbar(context: *widget.Context, state: *State, list: ui.Rect, total: u16, background: ui.Color) void {
    if (total <= list.h or list.h == 0) {
        return;
    }
    const area: ui.Rect = .{ .x = list.x + list.w - 1, .y = list.y, .w = 1, .h = list.h };
    const thumb = @max(1, area.h * area.h / total);
    const travel = area.h - thumb;
    const max_scroll = total - area.h;
    const offset: u16 = @intCast(@as(u32, state.scroll) * travel / max_scroll);
    var line: u16 = 0;
    while (line < area.h) : (line += 1) {
        const on_thumb = line >= offset and line < offset + thumb;
        _ = context.buffer.writeText(area, .{ .point = .{ .x = area.x, .y = area.y + line }, .text = if (on_thumb) "█" else "│", .style = .{
            .fg = if (on_thumb) context.palette.overlay1 else context.palette.surface1,
            .bg = background,
        } });
        const target: u16 = @intCast(@as(u32, line) * max_scroll / area.h);
        context.hits.add(.{ .x = area.x, .y = area.y + line, .w = 1, .h = 1 }, .{ .sidebar_scroll_to = target });
    }
}

fn drawRule(context: *widget.Context, area: ui.Rect, y: u16, background: ui.Color) u16 {
    const style: ui.Style = .{ .fg = context.palette.surface1, .bg = background };
    var x = area.x + 1;
    while (x < area.x + area.w - 1) : (x += 1)
        _ = context.buffer.writeText(area, .{ .point = .{ .x = x, .y = y }, .text = "─", .style = style });
    return y + 1;
}

fn drawRightSeparator(context: *widget.Context, area: ui.Rect, background: ui.Color) void {
    if (area.w == 0) {
        return;
    }
    const x = area.x + area.w - 1;
    var y = area.y;
    while (y < area.y + area.h) : (y += 1) {
        _ = context.buffer.writeText(area, .{ .point = .{ .x = x, .y = y }, .text = "│", .style = .{
            .fg = context.palette.surface1,
            .bg = background,
        } });
    }
}

fn cellBackground(context: *const widget.Context, transparent: bool) ui.Color {
    return if (transparent) .default else context.palette.panel_bg;
}

test "empty snapshot renders the minions header" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 48, 20);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var state: State = .{};
    const snapshot: Snapshot = .{};
    const palette = ui.theme.default_theme.palette;
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
    try std.testing.expectEqualStrings(minions_icon, buffer.at(2, 0).?.text());
    try std.testing.expectEqualStrings("m", buffer.at(4, 0).?.text());
    try std.testing.expectEqualStrings("─", buffer.at(2, 1).?.text());
    try std.testing.expect(hits.at(4, 0) == null);
}

test "agent snapshot renders compact selectable rows and status" {
    var snapshot: Snapshot = .{};
    const agent_entries = [_]AgentInput{.{
        .key = .{ .pane_id = @enumFromInt(41), .pane_generation = 3 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(2),
        },
        .pane_index = 2,
        .workspace_label = "telar",
        .tab_label = "test-2",
        .session_title = "Improve agent sidebar",
        .title_source = .generated,
        .title_state = .ready,
        .cwd_label = "~/sandbox/telar",
        .provider = .codex,
        .display_name = "Codex",
        .status = .blocked,
    }};
    _ = try snapshot.replace(.{ .revision = 1, .agents = &agent_entries });
    var buffer = try ui.Buffer.init(std.testing.allocator, 48, 20);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var state: State = .{};
    const palette = ui.theme.default_theme.palette;
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
        .focused_agent = agent_entries[0].key,
        .transparent = false,
    });
    try std.testing.expectEqual(@as(u16, 3), output.focused_card.?.h);
    try std.testing.expectEqualDeep(
        widget.Action{ .sidebar_focus_agent = agent_entries[0].key },
        hits.at(4, output.focused_card.?.y).?,
    );
    try std.testing.expectEqualStrings("I", buffer.at(6, output.focused_card.?.y).?.text());
    try std.testing.expectEqualStrings("t", buffer.at(6, output.focused_card.?.y + 1).?.text());
    try std.testing.expectEqualStrings("C", buffer.at(6, output.focused_card.?.y + 2).?.text());
}

test "active layout projects pane indices without mutating runtime agent state" {
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    const first: schema.PaneId = @enumFromInt(41);
    const second: schema.PaneId = @enumFromInt(42);
    var active = multiplexer.Model.init(std.testing.allocator);
    defer active.deinit();
    try active.addRoot(first, location, .{ .cols = 80, .rows = 24 });
    try active.split(first, second, location, .horizontal, .{ .w = 80, .h = 24 });
    var snapshot: Snapshot = .{};
    const agent: AgentInput = .{
        .key = .{ .pane_id = second, .pane_generation = 1 },
        .location = location,
        .pane_index = 9,
        .provider = .codex,
        .display_name = "Codex",
        .status = .ready,
    };
    _ = try snapshot.replace(.{ .revision = 1, .agents = &.{agent} });
    var state: State = .{};
    const input: Input = .{
        .area = .{},
        .snapshot = &snapshot,
        .state = &state,
        .active_model = &active,
        .transparent = false,
    };

    try std.testing.expectEqual(@as(u16, 2), projectedPaneIndex(input, &snapshot.slice()[0]));
    try std.testing.expectEqual(@as(u16, 9), snapshot.slice()[0].pane_index);
    try std.testing.expectEqual(@as(u64, 1), snapshot.revision);
}

test "agent without pane focus remains unhighlighted" {
    var snapshot: Snapshot = .{};
    const agent: AgentInput = .{
        .key = .{ .pane_id = @enumFromInt(41), .pane_generation = 3 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(2),
        },
        .pane_index = 2,
        .provider = .codex,
        .display_name = "Codex",
        .status = .ready,
    };
    _ = try snapshot.replace(.{ .revision = 1, .agents = &.{agent} });
    var buffer = try ui.Buffer.init(std.testing.allocator, 48, 20);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var state: State = .{};
    const palette = ui.theme.default_theme.palette;
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

    try std.testing.expect(output.focused_card == null);
    try std.testing.expectEqualStrings(" ", buffer.at(1, 3).?.text());
    try std.testing.expectEqualDeep(palette.panel_bg, buffer.at(10, 3).?.style.bg);
}

test "transparent Codex row publishes an official provider mark" {
    var snapshot: Snapshot = .{};
    const agent_entries = [_]AgentInput{.{
        .key = .{ .pane_id = @enumFromInt(41), .pane_generation = 3 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(2),
        },
        .pane_index = 2,
        .provider = .codex,
        .display_name = "Codex",
        .status = .ready,
    }};
    _ = try snapshot.replace(.{ .revision = 1, .agents = &agent_entries });
    var buffer = try ui.Buffer.init(std.testing.allocator, 48, 20);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var state: State = .{};
    const palette = ui.theme.default_theme.palette;
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
    try std.testing.expectEqual(ui.Rect{ .x = 3, .y = 2, .w = 2, .h = 2 }, output.provider_marks[0].area);
}

test "graphical focus exposes only the four rounded card corners" {
    var snapshot: Snapshot = .{};
    const agent_entries = [_]AgentInput{.{
        .key = .{ .pane_id = @enumFromInt(41), .pane_generation = 3 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(2),
        },
        .pane_index = 2,
        .provider = .codex,
        .display_name = "Codex",
        .status = .ready,
    }};
    _ = try snapshot.replace(.{ .revision = 1, .agents = &agent_entries });
    var buffer = try ui.Buffer.init(std.testing.allocator, 48, 20);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var state: State = .{};
    const palette = ui.theme.default_theme.palette;
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
        .focused_agent = agent_entries[0].key,
        .transparent = true,
        .rounded_focus = true,
    });
    const card = output.focused_card.?;
    try std.testing.expectEqual(ui.Color.default, buffer.at(card.x, card.y).?.style.bg);
    try std.testing.expectEqual(ui.Color.default, buffer.at(card.x + card.w - 1, card.y).?.style.bg);
    try std.testing.expectEqualDeep(palette.surface0, buffer.at(card.x + 1, card.y).?.style.bg);
    try std.testing.expectEqualDeep(palette.surface0, buffer.at(card.x, card.y + 1).?.style.bg);
    try std.testing.expectEqual(ui.Color.default, buffer.at(card.x, card.y + card.h - 1).?.style.bg);
    try std.testing.expectEqual(
        ui.Color.default,
        buffer.at(card.x + card.w - 1, card.y + card.h - 1).?.style.bg,
    );
}

test "hover covers the complete three-row agent card" {
    var snapshot: Snapshot = .{};
    const agent: AgentInput = .{
        .key = .{ .pane_id = @enumFromInt(41), .pane_generation = 3 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(2),
        },
        .pane_index = 2,
        .provider = .codex,
        .display_name = "Codex",
        .status = .working,
    };
    _ = try snapshot.replace(.{ .revision = 1, .agents = &.{agent} });
    var buffer = try ui.Buffer.init(std.testing.allocator, 48, 20);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var state: State = .{};
    const palette = ui.theme.default_theme.palette;
    const action: widget.Action = .{ .sidebar_focus_agent = agent.key };
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

    try std.testing.expectEqualDeep(palette.surface1, buffer.at(10, 2).?.style.bg);
    try std.testing.expectEqualDeep(palette.surface1, buffer.at(10, 4).?.style.bg);
    try std.testing.expectEqualDeep(action, hits.at(10, 4).?);
}

test "partial card scroll preserves visible rows, spacing, and hit targets" {
    const agent_entries = [_]AgentInput{
        .{
            .key = .{ .pane_id = @enumFromInt(41), .pane_generation = 3 },
            .location = .{
                .workspace = .{ .workspace = @enumFromInt(1) },
                .tab_id = @enumFromInt(2),
            },
            .pane_index = 2,
            .workspace_label = "telar",
            .tab_label = "main",
            .cwd_label = "~/sandbox/telar",
            .provider = .codex,
            .display_name = "Codex",
            .status = .ready,
        },
        .{
            .key = .{ .pane_id = @enumFromInt(42), .pane_generation = 1 },
            .location = .{
                .workspace = .{ .workspace = @enumFromInt(1) },
                .tab_id = @enumFromInt(2),
            },
            .pane_index = 3,
            .provider = .claude,
            .display_name = "Claude Code",
            .status = .working,
        },
    };
    var snapshot: Snapshot = .{};
    _ = try snapshot.replace(.{ .revision = 1, .agents = &agent_entries });
    var buffer = try ui.Buffer.init(std.testing.allocator, 48, 7);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var state: State = .{ .scroll = 1 };
    const palette = ui.theme.default_theme.palette;
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
        .focused_agent = agent_entries[0].key,
        .transparent = false,
        .rounded_focus = true,
    });

    try std.testing.expect(output.focused_card == null);
    try std.testing.expectEqual(@as(u16, 7), state.total_rows);
    try std.testing.expectEqualStrings("t", buffer.at(6, 2).?.text());
    try std.testing.expectEqualStrings("C", buffer.at(6, 3).?.text());
    try std.testing.expectEqualDeep(
        widget.Action{ .sidebar_focus_agent = agent_entries[0].key },
        hits.at(10, 2).?,
    );
    try std.testing.expectEqualDeep(palette.panel_bg, buffer.at(10, 4).?.style.bg);
    try std.testing.expect(hits.at(10, 4) == null);
    try std.testing.expectEqualDeep(
        widget.Action{ .sidebar_focus_agent = agent_entries[1].key },
        hits.at(10, 5).?,
    );
}

test "minions icon occupies one cell" {
    try std.testing.expectEqual(@as(u16, 1), ui.measure(minions_icon));
}

test "working status uses an animated glyph" {
    try std.testing.expect(statusIcon(.working, 0) != statusIcon(.working, 1));
    try std.testing.expectEqualStrings("✓", statusIcon(.ready, 0).unicodeGlyph());
    try std.testing.expectEqualStrings("✔", statusIcon(.done, 0).unicodeGlyph());
    try std.testing.expectEqualStrings("!", statusIcon(.blocked, 0).unicodeGlyph());
}

test "42 and 62 column cards reserve status before truncating context" {
    const long_title = "Investigate and improve the agent sidebar context without losing status";
    const agent: AgentInput = .{
        .key = .{ .pane_id = @enumFromInt(41), .pane_generation = 3 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(2),
        },
        .pane_index = 12,
        .workspace_label = "telar",
        .tab_label = "agent-sidebar-information",
        .session_title = long_title,
        .title_source = .generated,
        .title_state = .ready,
        .cwd_label = "…/abcdefghijklmnopqrstuvwx/agents/telar",
        .provider = .claude,
        .display_name = "Claude Code",
        .status = .blocked,
    };
    var snapshot: Snapshot = .{};
    _ = try snapshot.replace(.{ .revision = 1, .agents = &.{agent} });
    const widths = [_]u16{ 42, 62 };
    for (widths) |width| {
        var buffer = try ui.Buffer.init(std.testing.allocator, width, 12);
        defer buffer.deinit();
        var hits: widget.Hits = .{};
        var state: State = .{};
        const palette = ui.theme.default_theme.palette;
        var context: widget.Context = .{
            .buffer = &buffer,
            .hits = &hits,
            .palette = &palette,
            .hovered = null,
        };
        _ = render(&context, .{
            .area = buffer.area(),
            .snapshot = &snapshot,
            .state = &state,
            .transparent = false,
        });
        // The longest status remains intact against the right separator.
        const status_start = width - 14;
        try std.testing.expectEqualStrings("n", buffer.at(status_start, 2).?.text());
        try std.testing.expectEqualStrings("t", buffer.at(width - 4, 2).?.text());
        try std.testing.expectEqualStrings("│", buffer.at(width - 1, 2).?.text());
        // Breadcrumb and environment retain their semantic priority.
        try std.testing.expectEqualStrings("t", buffer.at(6, 3).?.text());
        try std.testing.expectEqualStrings("C", buffer.at(6, 4).?.text());
        try std.testing.expectEqualStrings("r", buffer.at(width - 4, 4).?.text());
    }
}
