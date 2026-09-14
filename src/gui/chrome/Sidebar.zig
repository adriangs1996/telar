const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const AgentCard = @import("AgentCard.zig");
const SlotRow = @import("SlotRow.zig");
const Sidebar = @This();

/// Rows the footer needs below the header and the list before it is drawn.
const min_footer_height = 5;

scroll: u16 = 0,
maximum_scroll: u16 = 0,

/// Paints bounded runtime agent cards, the configured footer row and retains
/// only the local scroll bound.
/// Example: `try sidebar.paint(&context, regions.sidebar);`
pub fn paint(sidebar: *Sidebar, context: *Context, area: core.Rect) !void {
    if (area.isEmpty()) {
        sidebar.maximum_scroll = 0;
        return;
    }

    const palette = context.canvas.theme.palette;
    try context.canvas.fill(area, palette.panel_bg);
    try context.canvas.text(area.row(0), .{ .text = "  minions", .color = palette.accent, .bold = true });
    if (area.w < 4 or area.h < 3) {
        sidebar.maximum_scroll = 0;
        return;
    }

    const footer = footerArea(area);
    if (!footer.isEmpty()) {
        const row: SlotRow = .{ .context = context, .slots = &context.projection.bar_state.layout.sidebar_footer };
        try row.paint(footer);
    }

    const list: core.Rect = .{ .x = area.x + 1, .y = area.y + 2, .w = area.w - 3, .h = area.h - 2 - footer.h };
    const agents = context.projection.agents.slice();
    const total: u16 = if (agents.len == 0) 0 else @intCast(agents.len * 4 - 1);
    sidebar.maximum_scroll = total -| list.h;
    sidebar.scroll = @min(sidebar.scroll, sidebar.maximum_scroll);
    if (agents.len == 0) {
        try context.label(list.row(0), "No active agents");
    }

    for (0..list.h) |line| {
        const row = sidebar.scroll + line;
        if (row >= total) {
            break;
        }

        if (row % 4 == 3) {
            continue;
        }

        const card: AgentCard = .{ .context = context, .agent = &agents[row / 4] };
        try card.paint(list.row(@intCast(line)), @intCast(row % 4));
    }

    if (sidebar.maximum_scroll != 0) {
        const thumb_height: u16 = @intCast(@max(1, @as(u32, list.h) * list.h / total));
        const offset: u16 = @intCast(@as(u32, sidebar.scroll) * (list.h - thumb_height) / sidebar.maximum_scroll);
        try context.canvas.fill(.{ .x = area.x + area.w - 2, .y = list.y + offset, .w = 1, .h = thumb_height }, palette.overlay0);
    }

    const separator: core.Rect = .{ .x = area.x + area.w - 1, .y = area.y, .w = 1, .h = area.h };
    try context.canvas.border(separator, palette.surface1);
    try context.hits.add(.{ .area = separator, .action = .resize_sidebar });
}

/// The one-row footer at the bottom of the sidebar, left of the resize handle.
/// Empty while the sidebar is too short to keep a header and a card visible.
/// Example: `const footer = Sidebar.footerArea(regions.sidebar);`
pub fn footerArea(area: core.Rect) core.Rect {
    if (area.h < min_footer_height or area.w < 4) {
        return .{};
    }

    return .{ .x = area.x, .y = area.y + area.h - 1, .w = area.w - 1, .h = 1 };
}

/// Scrolls by one bounded wheel step without a model mutation.
/// Example: `if (sidebar.wheel(.scroll_down)) chrome.invalidate();`
pub fn wheel(sidebar: *Sidebar, kind: client.Mouse.Kind) bool {
    const next = switch (kind) {
        .scroll_up => sidebar.scroll -| 3,
        .scroll_down => @min(sidebar.scroll +| 3, sidebar.maximum_scroll),
        else => sidebar.scroll,
    };
    if (next == sidebar.scroll) {
        return false;
    }

    sidebar.scroll = next;
    return true;
}
