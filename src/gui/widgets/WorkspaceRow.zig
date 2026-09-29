//! A project identity: favicon, name and path, with attention separate from selection.
const cellgrid = @import("cellgrid");
const data = @import("model");
const AgentCard = @import("AgentCard.zig");
const client = @import("telar-client");
const std = @import("std");
const core = @import("telar-core");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Label = @import("Label.zig");
const TextFit = @import("TextFit.zig");
const attention = @import("attention.zig");
const workspace_identity = @import("workspace_identity.zig");
const WorkspaceRow = @This();
const inactive_ink: cellgrid.Color = .rgb(.{ 115, 115, 115 });
/// The favicon side in logical chrome pixels, whole device pixels once scaled.
pub const icon_side: f32 = 18;

context: *const Context,
bounds: Rect,
index: usize,

/// Row height follows the chrome font and display scale.
/// Example: `const pitch = WorkspaceRow.height(canvas);`
pub fn height(canvas: *const Canvas) f32 {
    return canvas.chrome.rowHeight(.body) + canvas.chrome.rowHeight(.small) + canvas.chrome.px(20);
}

/// Draws only; the list clips both the row and its semantic hit target.
/// Example: `try row.draw(canvas);`
pub fn draw(self: WorkspaceRow, canvas: *Canvas) !void {
    const projection = self.context.projection;
    const workspace = projection.workspaces.workspaceAt(self.index);
    const selected = if (workspace_identity.activeId(projection)) |active| projection.workspaces.projectOf(active) == workspace else false;
    const palette = canvas.theme.palette;
    const bounds = self.bounds;
    const ink = if (selected) palette.text else inactive_ink;

    if (self.context.isHovered(.{ .intent = .{ .select_workspace = workspace } })) {
        try canvas.fillRoundedAt(bounds, .{ .radius = canvas.chrome.px(6), .color = palette.surface1 });
    }

    const inset = canvas.chrome.px(12);
    const side = @round(canvas.chrome.px(icon_side));
    const icon: Rect = .{ .x = bounds.x + inset, .y = bounds.y + (bounds.height - side) / 2, .width = side, .height = side };
    const sprite = if (self.context.favicons) |favicons| favicons.sprite(.{ .workspace = workspace }) else null;
    if (sprite) |value| {
        try canvas.spriteTintedAt(icon, .{ .sprite = value, .alpha = if (selected) 1 else 0.5 });
    } else {
        try canvas.iconAt(icon, .{ .text = AgentCard.project_glyph, .color = ink, .face = .sans, .size = .body });
    }

    const left = icon.x + icon.width + canvas.chrome.px(9);
    const available = @max(0, bounds.x + bounds.width - inset - left);
    const title: Rect = .{ .x = left, .y = bounds.y + canvas.chrome.px(10), .width = available, .height = canvas.chrome.rowHeight(.body) };
    const reserved = try self.drawAttention(canvas, title);
    var name = projection.workspaces.nameAt(self.index);
    if (selected and projection.model.workspaceName().len != 0) {
        name = projection.model.workspaceName();
    }

    try fittedText(canvas, .{ .x = title.x, .y = title.y, .width = @max(0, available - reserved), .height = title.height }, .{ .text = name, .color = ink, .bold = true, .face = .sans, .size = .body });
    var detail_buffer: [TextFit.max_bytes]u8 = undefined;
    const detail = worktreeSummary(projection, workspace, &detail_buffer) orelse projection.workspaces.pathAt(self.index);
    try fittedText(canvas, .{ .x = left, .y = title.y + title.height, .width = available, .height = canvas.chrome.rowHeight(.small) }, .{ .text = detail, .color = if (selected) palette.subtext0 else inactive_ink, .face = .sans, .size = .small });
}

/// `⎇ 3 · ◌ 1 ✓ 1  ~/path` for a project with worktrees: how many hang from
/// it, how many of their agents work and how many finished. Null without
/// worktrees, so the row keeps its path alone.
fn worktreeSummary(projection: *const client.Projection, workspace: core.WorkspaceId, buffer: []u8) ?[]const u8 {
    const snapshot = projection.workspaces;
    const worktrees = snapshot.worktreeCount(workspace);
    if (worktrees == 0) {
        return null;
    }

    var working: usize = 0;
    var finished: usize = 0;
    for (projection.agents.slice()) |*agent| {
        const agent_workspace = switch (agent.location.workspace) {
            .workspace => |id| id,
            .worktree => continue,
        };
        const in_worktree = snapshot.worktreeOfWorkspace(agent_workspace) != null or snapshot.worktree(agent.work_tree) != null;
        if (!in_worktree or snapshot.projectOf(agent_workspace) != workspace) {
            continue;
        }

        working += @intFromBool(agent.status == .working);
        finished += @intFromBool(agent.status == .done or agent.status == .ready);
    }

    const index = snapshot.indexOf(workspace) orelse return null;
    return std.fmt.bufPrint(buffer, "\u{2387} {d} \u{00b7} \u{25cc} {d} \u{2713} {d}  {s}", .{ worktrees, working, finished, snapshot.pathAt(index) }) catch null;
}

fn drawAttention(self: WorkspaceRow, canvas: *Canvas, area: Rect) !f32 {
    const workspace = self.context.projection.workspaces.workspaceAt(self.index);
    var count: u8 = 0;
    var urgent: ?*const data.Agent = null;
    for (self.context.projection.agents.slice()) |*agent| {
        const agent_workspace = switch (agent.location.workspace) {
            .workspace => |id| id,
            .worktree => continue,
        };
        if (self.context.projection.workspaces.projectOf(agent_workspace) != workspace or !attention.needsInput(agent.status)) {
            continue;
        }

        count += 1;
        if (urgent == null or client.agent_attention.compare(agent, urgent.?) == .lt) {
            urgent = agent;
        }
    }

    const agent = urgent orelse return 0;
    var buffer: [8]u8 = undefined;
    const selected = if (workspace_identity.activeId(self.context.projection)) |active| self.context.projection.workspaces.projectOf(active) == workspace else false;
    const label: Label = .{ .text = std.fmt.bufPrint(&buffer, "! {d}", .{count}) catch unreachable, .color = if (selected) attention.statusColor(canvas.theme.palette, agent.status) else inactive_ink, .face = .sans, .size = .small };
    const width = @min(area.width, try canvas.measure(label));
    _ = try canvas.textAt(.{ .x = area.x + area.width - width, .y = area.y, .width = width, .height = area.height }, label);
    return width + canvas.chrome.px(8);
}

fn fittedText(canvas: *Canvas, area: Rect, label: Label) !void {
    var buffer: [TextFit.max_bytes]u8 = undefined;
    const fit: TextFit = .{ .canvas = canvas, .width = area.width };
    var fitted = label;
    fitted.text = try fit.fit(label, &buffer);
    _ = try canvas.textAt(area, fitted);
}
