//! Stable runtime order, clipped project rows and a separate bounded viewport.
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const SidebarState = @import("SidebarState.zig");
const WorkspaceRow = @import("WorkspaceRow.zig");
const SidebarList = @import("SidebarList.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const WorkspaceList = @This();

context: *const Context,
state: *SidebarState,
bounds: Rect,

/// Retains scrolling between frames and reveals a newly selected workspace.
/// Example: `try projects.draw(canvas);`
pub fn draw(self: WorkspaceList, canvas: *Canvas) !void {
    const snapshot = self.context.projection.workspaces;
    const pitch = WorkspaceRow.height(canvas);
    const total = @as(f32, @floatFromInt(snapshot.project_count)) * pitch;
    const scroll = &self.state.projects;
    scroll.setBounds(pitch, total - self.bounds.height);
    self.state.revealWorkspace(self.context.projection, self.bounds.height);
    if (self.bounds.height <= 0 or self.bounds.width <= 0) {
        scroll.hide();
        return;
    }

    if (snapshot.project_count == 0) {
        const name = self.context.projection.model.workspaceName();
        _ = try canvas.textAt(self.bounds, .{ .text = if (name.len > 0) name else "No workspaces", .color = canvas.theme.palette.subtext0, .face = .sans, .size = .body });
        return;
    }

    const clip: SidebarList = .{ .bounds = self.bounds };
    const gutter = canvas.chrome.px(6);
    for (0..snapshot.project_count) |index| {
        const top = self.bounds.y + @as(f32, @floatFromInt(index)) * pitch - @as(f32, @floatFromInt(scroll.scroll));
        if (top + pitch <= self.bounds.y) {
            continue;
        }

        if (top >= self.bounds.y + self.bounds.height) {
            break;
        }

        const row: WorkspaceRow = .{ .context = self.context, .index = index, .bounds = .{ .x = self.bounds.x, .y = top, .width = @max(0, self.bounds.width - gutter), .height = pitch } };
        const first = canvas.quads.items().len;
        try row.draw(canvas);
        canvas.quads.clipFrom(first, self.bounds);
        self.context.bands.add(.{ .area = clip.hitArea(row.bounds), .action = .{ .intent = .{ .select_workspace = snapshot.workspaceAt(index) } } });
    }

    if (scroll.maximum_scroll != 0) {
        const thumb = @min(self.bounds.height, @max(canvas.chrome.rowHeight(.small), self.bounds.height * self.bounds.height / total));
        const offset = @as(f32, @floatFromInt(scroll.scroll)) * (self.bounds.height - thumb) / @as(f32, @floatFromInt(scroll.maximum_scroll));
        const width = canvas.chrome.px(3);
        try canvas.fillAt(.{ .x = self.bounds.x + self.bounds.width - width, .y = self.bounds.y + offset, .width = width, .height = thumb }, canvas.theme.palette.overlay0);
    }
}
