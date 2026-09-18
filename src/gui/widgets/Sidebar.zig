//! One frame of the project and agent sidebar. Layout, cards, clipping and controls
//! draw in device pixels; SidebarState owns scrolling and snapshot order.
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const SidebarState = @import("SidebarState.zig");
const Rect = @import("../render/Rect.zig");
const AgentCard = @import("AgentCard.zig");
const CardGeometry = @import("CardGeometry.zig");
const SidebarList = @import("SidebarList.zig");
const Label = @import("Label.zig");
const WorkspaceList = @import("WorkspaceList.zig");
const SidebarRegions = @import("SidebarRegions.zig");
const Sidebar = @This();

pub const margin = SidebarRegions.margin;
pub const header_gap = SidebarRegions.header_gap;
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
    sidebar.state.observe(context.projection.agents);
    const regions = if (context.sidebar_regions) |prepared| prepared.* else try SidebarRegions.resolve(canvas, area, context.projection.workspaces.count);

    try drawHeader(canvas, regions.projects_header, "projects");
    try (WorkspaceList{ .state = sidebar.state, .context = context, .bounds = regions.projects }).draw(canvas);
    try drawHeader(canvas, regions.agents_header, "agents");
    if (regions.agents.height > 0) {
        try sidebar.drawList(canvas, .{ .bounds = regions.agents });
    } else {
        sidebar.state.agents.hide();
    }

    try context.bands.add(.{ .area = canvas.sidebar.handle(area), .action = .resize_sidebar });
}

fn drawHeader(canvas: *Canvas, header: Rect, text: []const u8) !void {
    if (header.width <= 0 or header.height <= 0) {
        return;
    }

    const palette = canvas.theme.palette;
    const inset = canvas.chrome.px(8);
    const title: Label = .{ .text = text, .color = palette.text, .bold = true, .face = .sans, .size = .body };
    const label_area: Rect = .{ .x = header.x + inset, .y = header.y, .width = @max(0, header.width - 2 * inset), .height = header.height };
    _ = try canvas.textAt(label_area, title);
    if (@import("std").mem.eql(u8, text, "agents")) {
        const left = label_area.x + @min(label_area.width, try canvas.measure(title)) + canvas.chrome.px(10);
        try canvas.fillAt(.{ .x = left, .y = @floor(header.y + header.height / 2), .width = @max(0, label_area.x + label_area.width - left), .height = 1 }, palette.surface1);
    }
}

fn drawList(sidebar: Sidebar, canvas: *Canvas, list: SidebarList) !void {
    const context = sidebar.context;
    const state = sidebar.state;
    const palette = canvas.theme.palette;
    const agents = context.projection.agents.slice();
    const geometry = CardGeometry.derive(canvas.chrome, canvas.metrics);
    const count: f32 = @floatFromInt(state.order_len);
    const total = if (state.order_len == 0) 0 else count * geometry.pitch() - geometry.px(CardGeometry.spacing);
    const scroll = &state.agents;
    scroll.setBounds(geometry.pitch(), total - list.bounds.height);
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
        const top = list.bounds.y + @as(f32, @floatFromInt(position)) * geometry.pitch() - @as(f32, @floatFromInt(scroll.scroll));
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

    if (scroll.maximum_scroll != 0) {
        const thumb = @min(list.bounds.height, @max(geometry.small_row, list.bounds.height * list.bounds.height / total));
        const offset = @as(f32, @floatFromInt(scroll.scroll)) * (list.bounds.height - thumb) / @as(f32, @floatFromInt(scroll.maximum_scroll));
        try canvas.fillAt(.{ .x = list.bounds.x + list.bounds.width - scrollbar, .y = list.bounds.y + offset, .width = scrollbar, .height = thumb }, palette.overlay0);
    }
}
