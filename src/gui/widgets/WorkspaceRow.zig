//! A project identity: favicon, name and path, with attention separate from selection.
const std = @import("std");
const core = @import("telar-core");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const Label = @import("Label.zig");
const TextFit = @import("TextFit.zig");
const attention = @import("attention.zig");
const workspace_identity = @import("workspace_identity.zig");
const WorkspaceRow = @This();
const inactive_ink: core.Color = .{ .rgb = .{ 115, 115, 115 } };

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
pub fn draw(row: WorkspaceRow, canvas: *Canvas) !void {
    const projection = row.context.projection;
    const workspace = projection.workspaces.workspaceAt(row.index);
    const selected = workspace_identity.activeId(projection) == workspace;
    const palette = canvas.theme.palette;
    const bounds = row.bounds;
    const ink = if (selected) palette.text else inactive_ink;

    if (row.context.isHovered(.{ .intent = .{ .select_workspace = workspace } })) {
        try canvas.fillRoundedAt(bounds, .{ .radius = canvas.chrome.px(6), .color = palette.surface1 });
    }

    const inset = canvas.chrome.px(12);
    const icon_side = canvas.chrome.px(18);
    const icon: Rect = .{ .x = bounds.x + inset, .y = bounds.y + (bounds.height - icon_side) / 2, .width = icon_side, .height = icon_side };
    const sprite = if (row.context.favicons) |favicons| favicons.sprite(.{ .workspace = workspace }) else null;
    if (sprite) |value| {
        try canvas.spriteTintedAt(icon, .{ .sprite = value, .alpha = if (selected) 1 else 0.5 });
    } else {
        try canvas.iconAt(icon, .{ .text = @import("AgentCard.zig").project_glyph, .color = ink, .face = .sans, .size = .body });
    }

    const left = icon.x + icon.width + canvas.chrome.px(9);
    const available = @max(0, bounds.x + bounds.width - inset - left);
    const title: Rect = .{ .x = left, .y = bounds.y + canvas.chrome.px(10), .width = available, .height = canvas.chrome.rowHeight(.body) };
    const reserved = try row.drawAttention(canvas, title);
    var name = projection.workspaces.nameAt(row.index);
    if (selected and projection.tabs.displayedWorkspaceName().len != 0) {
        name = projection.tabs.displayedWorkspaceName();
    }

    try fittedText(canvas, .{ .x = title.x, .y = title.y, .width = @max(0, available - reserved), .height = title.height }, .{ .text = name, .color = ink, .bold = true, .face = .sans, .size = .body });
    try fittedText(canvas, .{ .x = left, .y = title.y + title.height, .width = available, .height = canvas.chrome.rowHeight(.small) }, .{ .text = projection.workspaces.pathAt(row.index), .color = if (selected) palette.subtext0 else inactive_ink, .face = .sans, .size = .small });
}

fn drawAttention(row: WorkspaceRow, canvas: *Canvas, area: Rect) !f32 {
    const workspace = row.context.projection.workspaces.workspaceAt(row.index);
    var count: u8 = 0;
    var urgent: ?*const @import("telar-client").Agent = null;
    for (row.context.projection.agents.slice()) |*agent| {
        if (!std.meta.eql(agent.location.workspace, core.WorkspaceLocation{ .workspace = workspace }) or !attention.needsInput(agent.status)) {
            continue;
        }

        count += 1;
        if (urgent == null or @import("telar-client").agent_attention.compare(agent, urgent.?) == .lt) {
            urgent = agent;
        }
    }

    const agent = urgent orelse return 0;
    var buffer: [8]u8 = undefined;
    const selected = workspace_identity.activeId(row.context.projection) == workspace;
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
