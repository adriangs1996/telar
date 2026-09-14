//! The agent list: a header with counts and one list of cards ordered by
//! attention, laid out in device pixels inside the sidebar's cell column.
//! The sidebar retains only its scroll offset, the order of the last
//! snapshot and when that snapshot arrived.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const AgentCard = @import("AgentCard.zig");
const CardGeometry = @import("CardGeometry.zig");
const SidebarList = @import("SidebarList.zig");
const Label = @import("Label.zig");
const SnapshotMark = @import("SnapshotMark.zig");
const Sidebar = @This();

pub const margin: f32 = 8;
pub const header_gap: f32 = 6;
pub const scrollbar_width: f32 = 3;

scroll: u16 = 0,
maximum_scroll: u16 = 0,
/// One wheel step in device pixels: the pitch of a card after the last paint.
step: u16 = 0,
order: [core.max_agent_snapshot_entries]u8 = undefined,
order_len: u8 = 0,
ordered: SnapshotMark = .{},
/// Monotonic seconds at which the ordered snapshot was first painted.
arrived_s: u32 = 0,

/// Paints the header, the ordered cards and the resize border; retains only
/// the local scroll bound and the snapshot order.
/// Example: `try sidebar.paint(&context, regions.sidebar);`
pub fn paint(sidebar: *Sidebar, context: *Context, area: core.Rect) !void {
    if (area.isEmpty()) {
        sidebar.maximum_scroll = 0;
        return;
    }

    const canvas = context.canvas;
    const palette = canvas.theme.palette;
    try canvas.fill(area, palette.panel_bg);
    const separator: core.Rect = .{ .x = area.x + area.w - 1, .y = area.y, .w = 1, .h = area.h };
    try canvas.border(separator, palette.surface1);
    const content: core.Rect = .{ .x = area.x, .y = area.y, .w = area.w - 1, .h = area.h };
    sidebar.observe(context);
    if (content.isEmpty()) {
        sidebar.maximum_scroll = 0;
        try context.hits.add(.{ .area = separator, .action = .resize_sidebar });
        return;
    }

    const geometry = CardGeometry.derive(canvas.metrics);
    const bounds = canvas.rect(content);
    const header: Rect = .{ .x = bounds.x + margin, .y = bounds.y + margin, .width = @max(0, bounds.width - 2 * margin), .height = geometry.row_height };
    try paintHeader(context, header);
    const list: Rect = .{
        .x = header.x,
        .y = header.y + header.height + header_gap,
        .width = header.width,
        .height = @max(0, bounds.y + bounds.height - margin - (header.y + header.height + header_gap)),
    };
    try sidebar.paintList(context, .{ .cells = content, .bounds = list, .geometry = geometry });
    try context.hits.add(.{ .area = separator, .action = .resize_sidebar });
}

/// Scrolls by one card without a model mutation.
/// Example: `if (sidebar.wheel(.scroll_down)) chrome.invalidate();`
pub fn wheel(sidebar: *Sidebar, kind: client.Mouse.Kind) bool {
    const next = switch (kind) {
        .scroll_up => sidebar.scroll -| sidebar.step,
        .scroll_down => @min(sidebar.scroll +| sidebar.step, sidebar.maximum_scroll),
        else => sidebar.scroll,
    };
    if (next == sidebar.scroll) {
        return false;
    }

    sidebar.scroll = next;
    return true;
}

/// The attention order of the last painted snapshot, as replica indices.
/// Example: `for (sidebar.ordering()) |index| { ... }`
pub fn ordering(sidebar: *const Sidebar) []const u8 {
    return sidebar.order[0..sidebar.order_len];
}

// Sorting happens once per snapshot: the comparator reads replica fields
// only, so neither a frame nor a clock tick can change the order.
fn observe(sidebar: *Sidebar, context: *Context) void {
    const snapshot = context.projection.agents;
    const mark = SnapshotMark.of(snapshot);
    if (sidebar.ordered.eql(mark)) {
        return;
    }

    const agents = snapshot.slice();
    sidebar.order_len = @intCast(@min(agents.len, sidebar.order.len));
    for (sidebar.order[0..sidebar.order_len], 0..) |*slot, index| {
        slot.* = @intCast(index);
    }

    std.sort.pdq(u8, sidebar.order[0..sidebar.order_len], agents, indexLessThan);
    sidebar.ordered = mark;
    sidebar.arrived_s = context.now_s;
}

fn indexLessThan(agents: []const client.Agent, left: u8, right: u8) bool {
    return client.agent_attention.lessThan({}, &agents[left], &agents[right]);
}

fn paintHeader(context: *Context, header: Rect) !void {
    const canvas = context.canvas;
    const palette = canvas.theme.palette;
    const title: Label = .{ .text = "agents", .color = palette.text, .bold = true, .face = .sans };
    const title_width = try canvas.measure(title);
    _ = try canvas.textAt(header, title);
    var buffer: [48]u8 = undefined;
    const agents = context.projection.agents.slice();
    var attention: usize = 0;
    for (agents) |agent| {
        attention += @intFromBool(client.agent_attention.group(agent.status) == .needs_input);
    }

    const counts: Label = .{ .text = std.fmt.bufPrint(&buffer, "{d} \u{00b7} {d} need you", .{ agents.len, attention }) catch unreachable, .color = palette.subtext0, .face = .sans };
    const counts_width = try canvas.measure(counts);
    if (title_width + CardGeometry.gap + counts_width > header.width) {
        return;
    }

    _ = try canvas.textAt(.{ .x = header.x + header.width - counts_width, .y = header.y, .width = counts_width, .height = header.height }, counts);
}

fn paintList(sidebar: *Sidebar, context: *Context, list: SidebarList) !void {
    const canvas = context.canvas;
    const palette = canvas.theme.palette;
    const agents = context.projection.agents.slice();
    const geometry = list.geometry;
    const count: f32 = @floatFromInt(sidebar.order_len);
    const total = if (sidebar.order_len == 0) 0 else count * geometry.pitch() - CardGeometry.spacing;
    sidebar.step = @intFromFloat(@min(65535, geometry.pitch()));
    sidebar.maximum_scroll = @intFromFloat(@min(65535, @max(0, total - list.bounds.height)));
    sidebar.scroll = @min(sidebar.scroll, sidebar.maximum_scroll);
    if (sidebar.order_len == 0) {
        _ = try canvas.textAt(.{ .x = list.bounds.x, .y = list.bounds.y, .width = list.bounds.width, .height = geometry.row_height }, .{ .text = "No active agents", .color = palette.subtext0, .face = .sans });
        return;
    }

    const list_bottom = list.bounds.y + list.bounds.height;
    const card_width = @max(0, list.bounds.width - scrollbar_width - CardGeometry.spacing);
    for (sidebar.ordering(), 0..) |index, position| {
        const top = list.bounds.y + @as(f32, @floatFromInt(position)) * geometry.pitch() - @as(f32, @floatFromInt(sidebar.scroll));
        if (top + geometry.height() <= list.bounds.y) {
            continue;
        }

        if (top >= list_bottom) {
            break;
        }

        const agent = &agents[index];
        const bounds: Rect = .{ .x = list.bounds.x, .y = top, .width = card_width, .height = geometry.height() };
        const card: AgentCard = .{
            .context = context,
            .agent = agent,
            .geometry = geometry,
            .age_s = agent.statusAgeSeconds() +| (context.now_s -| sidebar.arrived_s),
        };
        const first = canvas.quads.items().len;
        try card.paint(bounds);
        canvas.quads.clipFrom(first, list.bounds);
        try context.hits.add(.{ .area = list.hitCells(canvas, bounds), .action = card.action() });
    }

    if (sidebar.maximum_scroll != 0) {
        const thumb = @max(geometry.row_height, list.bounds.height * list.bounds.height / total);
        const offset = @as(f32, @floatFromInt(sidebar.scroll)) * (list.bounds.height - thumb) / @as(f32, @floatFromInt(sidebar.maximum_scroll));
        try canvas.fillAt(.{ .x = list.bounds.x + list.bounds.width - scrollbar_width, .y = list.bounds.y + offset, .width = scrollbar_width, .height = thumb }, palette.overlay0);
    }
}
