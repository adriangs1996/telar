//! Stable runtime order, clipped project rows and a separate bounded viewport.
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const SidebarState = @import("SidebarState.zig");
const WorkspaceRow = @import("WorkspaceRow.zig");
const SidebarList = @import("SidebarList.zig");
const Rect = @import("../render/Rect.zig");
const WorkspaceList = @This();

context: *const Context,
state: *SidebarState,
bounds: Rect,

/// Retains scrolling between frames and reveals a newly selected workspace.
/// Example: `try projects.draw(canvas);`
pub fn draw(list: WorkspaceList, canvas: *Canvas) !void {
    const snapshot = list.context.projection.workspaces;
    const pitch = WorkspaceRow.height(canvas);
    const total = @as(f32, @floatFromInt(snapshot.count)) * pitch;
    const scroll = &list.state.projects;
    scroll.setBounds(pitch, total - list.bounds.height);
    list.state.revealWorkspace(list.context.projection, list.bounds.height);
    if (list.bounds.height <= 0 or list.bounds.width <= 0) {
        scroll.hide();
        return;
    }

    if (snapshot.count == 0) {
        const name = list.context.projection.tabs.displayedWorkspaceName();
        _ = try canvas.textAt(list.bounds, .{ .text = if (name.len > 0) name else "No workspaces", .color = canvas.theme.palette.subtext0, .face = .sans, .size = .body });
        return;
    }

    const clip: SidebarList = .{ .bounds = list.bounds };
    const gutter = canvas.chrome.px(6);
    for (0..snapshot.count) |index| {
        const top = list.bounds.y + @as(f32, @floatFromInt(index)) * pitch - @as(f32, @floatFromInt(scroll.scroll));
        if (top + pitch <= list.bounds.y) {
            continue;
        }

        if (top >= list.bounds.y + list.bounds.height) {
            break;
        }

        const row: WorkspaceRow = .{ .context = list.context, .index = index, .bounds = .{ .x = list.bounds.x, .y = top, .width = @max(0, list.bounds.width - gutter), .height = pitch } };
        const first = canvas.quads.items().len;
        try row.draw(canvas);
        canvas.quads.clipFrom(first, list.bounds);
        try list.context.bands.add(.{ .area = clip.hitArea(row.bounds), .action = .{ .intent = .{ .select_workspace = snapshot.workspaceAt(index) } } });
    }

    if (scroll.maximum_scroll != 0) {
        const thumb = @min(list.bounds.height, @max(canvas.chrome.rowHeight(.small), list.bounds.height * list.bounds.height / total));
        const offset = @as(f32, @floatFromInt(scroll.scroll)) * (list.bounds.height - thumb) / @as(f32, @floatFromInt(scroll.maximum_scroll));
        const width = canvas.chrome.px(3);
        try canvas.fillAt(.{ .x = list.bounds.x + list.bounds.width - width, .y = list.bounds.y + offset, .width = width, .height = thumb }, canvas.theme.palette.overlay0);
    }
}
