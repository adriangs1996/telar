//! The agent list: a header and one list of cards ordered by
//! attention, laid out in device pixels inside the sidebar band. The
//! sidebar retains only its scroll offset and the order of the last snapshot.
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
const SlotRow = @import("SlotRow.zig");
const Sidebar = @This();

/// Terminal rows the band needs before the footer row is drawn: the header,
/// a gap and one card above it.
const min_footer_rows: f32 = 5;

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

/// Paints the band, the header, the ordered cards, the footer slot row, the
/// edge line and the resize handle; retains only the local scroll bound
/// and the snapshot order. Every target goes to the band hit map.
/// Example: `try sidebar.paint(&context, bands.sidebar);`
pub fn paint(sidebar: *Sidebar, context: *Context, area: Rect) !void {
    if (area.width <= 0 or area.height <= 0) {
        sidebar.maximum_scroll = 0;
        return;
    }

    const canvas = context.canvas;
    const palette = canvas.theme.palette;
    // The band ends at its edge line; the gap past it keeps the window's own
    // background and opacity like the workbench.
    try canvas.panelAt(.{ .x = area.x, .y = area.y, .width = area.width - 1, .height = area.height });
    try canvas.fillAt(.{ .x = area.x + area.width - 1, .y = area.y, .width = 1, .height = area.height }, palette.surface1);
    const footer = footerArea(canvas.metrics, area);
    const inset = canvas.chrome.px(margin);
    if (footer.height > 0) {
        const row: SlotRow = .{ .context = context, .slots = &context.projection.bar_state.layout.sidebar_footer };
        try row.paintIn(footer);
    }

    sidebar.observe(context);
    const geometry = CardGeometry.derive(canvas.chrome, canvas.metrics);
    const header: Rect = .{ .x = area.x + inset, .y = area.y + inset, .width = @max(0, area.width - 1 - 2 * inset), .height = canvas.chrome.rowHeight(.body) };
    const content_bottom = if (footer.height > 0) footer.y - inset else area.y + area.height - inset;
    const list: Rect = .{
        .x = header.x,
        .y = header.y + header.height + canvas.chrome.px(header_gap),
        .width = header.width,
        .height = @max(0, content_bottom - (header.y + header.height + canvas.chrome.px(header_gap))),
    };
    if (header.width <= 0 or list.height <= 0) {
        sidebar.maximum_scroll = 0;
    } else {
        try paintHeader(context, header);
        try sidebar.paintList(context, .{ .bounds = list, .geometry = geometry });
    }

    try context.bands.add(.{ .area = canvas.sidebar.handle(area), .action = .resize_sidebar });
}

/// The footer row at the bottom of the band, left of the edge line: one
/// terminal row tall, so the Lua slots paint in cells lent to it. Empty
/// while the band is too short to keep a header and a card above it.
/// Example: `const footer = Sidebar.footerArea(canvas.metrics, bands.sidebar);`
pub fn footerArea(metrics: @import("../TerminalMetrics.zig"), area: Rect) Rect {
    const row: f32 = @floatFromInt(metrics.cell_height);
    const cell: f32 = @floatFromInt(metrics.cell_width);
    if (area.height < min_footer_rows * row or area.width - 1 - 2 * margin < 3 * cell) {
        return .{ .x = area.x, .y = area.y, .width = 0, .height = 0 };
    }

    return .{ .x = area.x + margin, .y = area.y + area.height - margin - row, .width = area.width - 1 - 2 * margin, .height = row };
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
}

fn indexLessThan(agents: []const client.Agent, left: u8, right: u8) bool {
    return client.agent_attention.lessThan({}, &agents[left], &agents[right]);
}

fn paintHeader(context: *Context, header: Rect) !void {
    const canvas = context.canvas;
    const palette = canvas.theme.palette;
    const title: Label = .{ .text = "agents", .color = palette.text, .bold = true, .face = .sans, .size = .body };
    _ = try canvas.textAt(header, title);
}

fn paintList(sidebar: *Sidebar, context: *Context, list: SidebarList) !void {
    const canvas = context.canvas;
    const palette = canvas.theme.palette;
    const agents = context.projection.agents.slice();
    const geometry = list.geometry;
    const count: f32 = @floatFromInt(sidebar.order_len);
    const total = if (sidebar.order_len == 0) 0 else count * geometry.pitch() - geometry.px(CardGeometry.spacing);
    sidebar.step = @intFromFloat(@min(65535, geometry.pitch()));
    sidebar.maximum_scroll = @intFromFloat(@min(65535, @max(0, total - list.bounds.height)));
    sidebar.scroll = @min(sidebar.scroll, sidebar.maximum_scroll);
    if (sidebar.order_len == 0) {
        _ = try canvas.textAt(
            .{
                .x = list.bounds.x,
                .y = list.bounds.y,
                .width = list.bounds.width,
                .height = canvas.chrome.rowHeight(.body),
            },
            .{
                .text = "No active agents",
                .color = palette.subtext0,
                .face = .sans,
                .size = .body,
            },
        );
        return;
    }

    const list_bottom = list.bounds.y + list.bounds.height;
    const scrollbar = canvas.chrome.px(scrollbar_width);
    const card_width = @max(0, list.bounds.width - scrollbar - geometry.px(CardGeometry.spacing));
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
            .age_s = context.statusAgeAt(index),
            .project_icon = if (context.favicons) |favicons| favicons.sprite(agent.location.workspace) else null,
        };
        const first = canvas.quads.items().len;
        try card.paint(bounds);
        canvas.quads.clipFrom(first, list.bounds);
        try context.bands.add(.{ .area = list.hitArea(bounds), .action = card.action() });
    }

    if (sidebar.maximum_scroll != 0) {
        const thumb = @max(geometry.small_row, list.bounds.height * list.bounds.height / total);
        const offset = @as(f32, @floatFromInt(sidebar.scroll)) * (list.bounds.height - thumb) / @as(f32, @floatFromInt(sidebar.maximum_scroll));
        try canvas.fillAt(.{ .x = list.bounds.x + list.bounds.width - scrollbar, .y = list.bounds.y + offset, .width = scrollbar, .height = thumb }, palette.overlay0);
    }
}
