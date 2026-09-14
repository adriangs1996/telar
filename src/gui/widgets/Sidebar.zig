//! One frame of the agent sidebar. Layout, cards, clipping and controls
//! draw in device pixels; SidebarState owns scrolling and snapshot order.
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const SidebarState = @import("SidebarState.zig");
const Rect = @import("../render/Rect.zig");
const AgentCard = @import("AgentCard.zig");
const CardGeometry = @import("CardGeometry.zig");
const SidebarList = @import("SidebarList.zig");
const Label = @import("Label.zig");
const Layout = @import("../layout/Layout.zig");
const LayoutItem = @import("../layout/Item.zig");
const Sidebar = @This();

pub const margin: f32 = 8;
pub const header_gap: f32 = 6;
pub const scrollbar_width: f32 = 3;

state: *SidebarState,
context: *const Context,
area: Rect,

/// Draws the band and its ordered cards with matching clipped controls.
/// Example: `try sidebar.draw(canvas);`
pub fn draw(sidebar: Sidebar, canvas: *Canvas) !void {
    const context = sidebar.context;
    const area = sidebar.area;
    if (area.width <= 0 or area.height <= 0) {
        sidebar.state.hide();
        return;
    }

    const palette = canvas.theme.palette;
    // The band ends at its edge line; the gap past it keeps the window's own
    // background and opacity like the workbench.
    try canvas.panelAt(.{ .x = area.x, .y = area.y, .width = area.width - 1, .height = area.height });
    try canvas.fillAt(.{ .x = area.x + area.width - 1, .y = area.y, .width = 1, .height = area.height }, palette.surface1);
    const inset = canvas.chrome.px(margin);
    sidebar.state.observe(context.projection.agents);
    const geometry = CardGeometry.derive(canvas.chrome, canvas.metrics);
    const content_bottom = area.y + area.height - inset;
    var rows = [_]LayoutItem{ .{ .height = .{ .fixed = canvas.chrome.rowHeight(.body) } }, .{} };
    try (Layout{
        .area = .{ .x = area.x + inset, .y = area.y + inset, .width = @max(0, area.width - 1 - 2 * inset), .height = @max(0, content_bottom - area.y - inset) },
        .direction = .column,
        .gap = canvas.chrome.px(header_gap),
    }).resolve(&rows);
    const header = rows[0].bounds;
    const list = rows[1].bounds;
    if (header.width <= 0 or list.height <= 0) {
        sidebar.state.hide();
    } else {
        try drawHeader(canvas, header);
        try sidebar.drawList(canvas, .{ .bounds = list, .geometry = geometry });
    }

    try context.bands.add(.{ .area = canvas.sidebar.handle(area), .action = .resize_sidebar });
}

fn drawHeader(canvas: *Canvas, header: Rect) !void {
    const palette = canvas.theme.palette;
    const title: Label = .{ .text = "agents", .color = palette.text, .bold = true, .face = .sans, .size = .body };
    _ = try canvas.textAt(header, title);
}

fn drawList(sidebar: Sidebar, canvas: *Canvas, list: SidebarList) !void {
    const context = sidebar.context;
    const state = sidebar.state;
    const palette = canvas.theme.palette;
    const agents = context.projection.agents.slice();
    const geometry = list.geometry;
    const count: f32 = @floatFromInt(state.order_len);
    const total = if (state.order_len == 0) 0 else count * geometry.pitch() - geometry.px(CardGeometry.spacing);
    state.setScrollBounds(geometry.pitch(), total - list.bounds.height);
    if (state.order_len == 0) {
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
    for (state.ordering(), 0..) |index, position| {
        const top = list.bounds.y + @as(f32, @floatFromInt(position)) * geometry.pitch() - @as(f32, @floatFromInt(state.scroll));
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
            .bounds = bounds,
            .agent = agent,
            .geometry = geometry,
            .age_s = context.statusAgeAt(index),
            .project_icon = if (context.favicons) |favicons| favicons.sprite(agent.location.workspace) else null,
        };
        const first = canvas.quads.items().len;
        try card.draw(canvas);
        canvas.quads.clipFrom(first, list.bounds);
        try context.bands.add(.{ .area = list.hitArea(bounds), .action = card.action() });
    }

    if (state.maximum_scroll != 0) {
        const thumb = @max(geometry.small_row, list.bounds.height * list.bounds.height / total);
        const offset = @as(f32, @floatFromInt(state.scroll)) * (list.bounds.height - thumb) / @as(f32, @floatFromInt(state.maximum_scroll));
        try canvas.fillAt(.{ .x = list.bounds.x + list.bounds.width - scrollbar, .y = list.bounds.y + offset, .width = scrollbar, .height = thumb }, palette.overlay0);
    }
}
