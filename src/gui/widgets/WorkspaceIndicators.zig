//! Compact numbered project marks in runtime order, with no tab-like surfaces.
//! Overflow is used only when the available pixels cannot hold every project.
const cellgrid = @import("cellgrid");
const WorkspaceMark = @import("WorkspaceMark.zig");
const std = @import("std");
const core = @import("telar-core");
const data = @import("model");
const Context = @import("Context.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const attention = @import("attention.zig");
const workspace_identity = @import("workspace_identity.zig");
const Label = @import("Label.zig");
const Layout = gfx.Layout;
const Item = gfx.Item;
const WorkspaceWindow = @import("WorkspaceWindow.zig");
const Canvas = @import("Canvas.zig");
const PixelButton = @import("PixelButton.zig");
const SpriteSize = @import("../image/SpriteSize.zig").SpriteSize;
const WorkspaceIndicators = @This();

context: *const Context,
area: Rect,

/// Reserves only the space needed by the project marks, independent of names.
/// Example: `const width = WorkspaceIndicators.preferredWidth(context);`
pub fn preferredWidth(context: *const Context) f32 {
    const projection = context.projection;
    const current = context.workspaceId();
    const index = if (current) |id| projection.workspaces.indexOf(id) else null;
    if (index == null or index.? >= projection.workspaces.project_count) {
        return 320;
    }

    const count: f32 = @floatFromInt(projection.workspaces.project_count);
    return count * (indicator_width + logical_gap) - logical_gap;
}

/// Paints the parent-reserved workspace region using its resolved pixel layout.
/// Example: `try indicators.draw(canvas);`
pub fn draw(self: WorkspaceIndicators, canvas: *Canvas) !void {
    const projection = self.context.projection;
    if (self.area.width <= 0 or self.area.height <= 0) {
        return;
    }

    const snapshot = projection.workspaces;
    const current = (if (self.context.workspaceId()) |id| snapshot.indexOf(id) else null) orelse return self.activeWorkspace(canvas);
    if (current >= snapshot.project_count) {
        return self.activeWorkspace(canvas);
    }

    const gap = canvas.chrome.px(logical_gap);
    const counter = canvas.chrome.px(counter_width);
    const width = canvas.chrome.px(indicator_width);
    var capacity: usize = @intFromFloat(@floor((self.area.width + gap) / (width + gap)));
    const counters = capacity < snapshot.project_count and self.area.width >= width + 2 * (counter + gap);
    if (counters) {
        capacity = @intFromFloat(@floor((self.area.width - 2 * (counter + gap) + gap) / (width + gap)));
    }

    const window = WorkspaceWindow.centered(snapshot.project_count, current, @max(1, capacity));
    const offset: usize = if (counters) 1 else 0;
    const length = window.count + 2 * offset;
    var children: [core.max_workspace_list_entries + 2]Item = @splat(.{ .width = .{ .fixed = @min(width, self.area.width) } });
    if (counters) {
        children[0] = .{ .width = .{ .fixed = counter } };
        children[length - 1] = .{ .width = .{ .fixed = counter } };
    }

    try (Layout{ .area = self.area, .gap = gap }).resolve(children[0..length]);
    if (counters) {
        if (window.previous()) |index| {
            const counter_widget: WorkspaceIndicators = .{ .context = self.context, .area = children[0].bounds };
            try counter_widget.overflowCounter(canvas, .{ 0, index + 1 });
        }
    }

    for (0..window.count) |index| {
        const workspace_widget: WorkspaceIndicators = .{ .context = self.context, .area = children[offset + index].bounds };
        try workspace_widget.workspace(canvas, window.first + index);
    }

    if (counters) {
        if (window.next()) |index| {
            const counter_widget: WorkspaceIndicators = .{ .context = self.context, .area = children[length - 1].bounds };
            try counter_widget.overflowCounter(canvas, .{ index, snapshot.project_count });
        }
    }
}

/// The location of a workspace that is not a numbered project. A worktree's
/// workspace reads `project › ⎇ branch`, the branch in the accent color, so a
/// worktree tab is never mistaken for the main checkout. The crumb is not a
/// control: the project's row in the sidebar and `leave-worktree` return,
/// and a second target with the row's action would share its identity.
fn activeWorkspace(self: WorkspaceIndicators, canvas: *Canvas) !void {
    const projection = self.context.projection;
    if (self.context.workspaceId()) |id| {
        if (projection.workspaces.worktreeOfWorkspace(id)) |row| {
            return self.worktreeBreadcrumb(canvas, row);
        }
    }

    var storage: [workspace_identity.label_bytes]u8 = undefined;
    const text = workspace_identity.contextLabel(projection.model, &storage);
    const label: Label = .{ .text = text, .color = canvas.theme.palette.text, .bold = true, .face = .sans, .size = .body };
    _ = try canvas.textAt(self.area, label);
}

fn worktreeBreadcrumb(self: WorkspaceIndicators, canvas: *Canvas, row: *const data.WorktreeRow) !void {
    const palette = canvas.theme.palette;
    const snapshot = self.context.projection.workspaces;
    const source_name = if (snapshot.indexOf(row.source)) |index| snapshot.nameAt(index) else "";
    // Room for the longest workspace name, so the prefix always formats.
    var storage: [core.max_workspace_name_bytes + " \u{203a} ".len]u8 = undefined;
    const prefix = std.fmt.bufPrint(&storage, "{s} \u{203a} ", .{source_name}) catch "";
    const project: Label = .{ .text = prefix, .color = palette.subtext0, .face = .sans, .size = .body };
    const prefix_width = if (prefix.len == 0) 0 else try canvas.measure(project);
    if (prefix.len != 0) {
        _ = try canvas.textAt(self.area, project);
    }

    var branch_storage: [core.max_git_branch_bytes + 8]u8 = undefined;
    const branch_text = std.fmt.bufPrint(&branch_storage, "\u{2387} {s}", .{row.handle()}) catch row.handle();
    const branch: Label = .{ .text = branch_text, .color = palette.accent, .bold = true, .face = .sans, .size = .body };
    _ = try canvas.textAt(.{ .x = self.area.x + prefix_width, .y = self.area.y, .width = @max(0, self.area.width - prefix_width), .height = self.area.height }, branch);
}

fn workspace(self: WorkspaceIndicators, canvas: *Canvas, index: usize) !void {
    const projection = self.context.projection;
    const id = projection.workspaces.workspaceAt(index);
    const selected = self.context.workspaceId() == id;
    const hovered = self.context.isHovered(.{ .intent = .{ .select_workspace = id } });
    const palette = canvas.theme.palette;
    const ink = if (selected) palette.accent else if (hovered) palette.text else palette.subtext0;
    const bounds = self.area;
    const first = canvas.quads.items().len;
    const chrome = canvas.chrome;
    const content_height = @max(0, bounds.height - chrome.px(5));
    var storage: [8]u8 = undefined;
    const label: Label = .{ .text = std.fmt.bufPrint(&storage, "{d}", .{index + 1}) catch unreachable, .color = ink, .bold = selected, .face = .sans, .size = .small };
    _ = try canvas.textAt(.{ .x = bounds.x + chrome.px(3), .y = bounds.y, .width = chrome.px(14), .height = content_height }, label);

    const side = @round(chrome.px(SpriteSize.small.logical()));
    const icon: Rect = .{ .x = bounds.x + chrome.px(20), .y = bounds.y + (content_height - side) / 2, .width = side, .height = side };
    const mark: WorkspaceMark = .{
        .context = self.context,
        .workspace = id,
        .bounds = icon,
        .ink = ink,
        .emphasized = selected or hovered,
        .sprite_size = .small,
        .name = projection.workspaces.nameAt(index),
    };
    try mark.draw(canvas);

    if (selected) {
        const diameter = chrome.px(3);
        try canvas.fillRoundedAt(.{ .x = bounds.x + (bounds.width - diameter) / 2, .y = bounds.y + bounds.height - diameter, .width = diameter, .height = diameter }, .{ .radius = diameter / 2, .color = palette.accent });
    }

    if (attention.workspaceDot(projection, palette, id)) |color| {
        try self.drawAttention(canvas, color);
    }

    canvas.quads.clipFrom(first, bounds);
    self.context.bands.add(.{ .area = bounds, .action = .{ .intent = .{ .select_workspace = id } } });
}

fn overflowCounter(self: WorkspaceIndicators, canvas: *Canvas, range: [2]usize) !void {
    const previous = range[0] == 0;
    const index = if (previous) range[1] - 1 else range[0];
    const total = range[1] - range[0];
    var storage: [16]u8 = undefined;
    const text = if (previous)
        std.fmt.bufPrint(&storage, "‹{d}", .{total}) catch unreachable
    else
        std.fmt.bufPrint(&storage, "{d}›", .{total}) catch unreachable;
    const button: PixelButton = .{
        .context = self.context,
        .area = self.area,
        .intent = .{ .select_workspace = self.context.projection.workspaces.workspaceAt(index) },
        .text = text,
        .alignment = .center,
        .background = false,
        .size = .small,
        .inset = canvas.chrome.px(2),
    };
    try button.draw(canvas);

    if (attention.listRangeDot(self.context.projection, canvas.theme.palette, range)) |color| {
        try self.drawAttention(canvas, color);
    }
}

fn drawAttention(self: WorkspaceIndicators, canvas: *Canvas, color: cellgrid.Color) !void {
    const bounds = self.area;
    const diameter = @min(canvas.chrome.px(4), @min(bounds.width, bounds.height));
    try canvas.fillRoundedAt(.{ .x = bounds.x + bounds.width - diameter, .y = bounds.y, .width = diameter, .height = diameter }, .{ .radius = diameter / 2, .color = color });
}


const logical_gap: f32 = 4;
const counter_width: f32 = 28;
const indicator_width: f32 = 40;
