//! At most three equal workspace slots, centered on the active workspace in
//! stable runtime order. Hidden neighbors retain their attention indicators.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const attention = @import("attention.zig");
const Label = @import("Label.zig");
const Layout = @import("../layout/Layout.zig");
const Item = @import("../layout/Item.zig");
const WorkspaceWindow = @import("WorkspaceWindow.zig");
const Canvas = @import("Canvas.zig");
const PixelButton = @import("PixelButton.zig");
const WorkspacePills = @This();

context: *const Context,
area: Rect,

/// Logical width of the three-workspace area, independent of label lengths.
pub const preferred_width: f32 = 320;

/// Paints the parent-reserved workspace region using its resolved pixel layout.
/// Example: `try pills.draw(canvas);`
pub fn draw(pills: WorkspacePills, canvas: *Canvas) !void {
    const projection = pills.context.projection;
    if (pills.area.width <= 0 or pills.area.height <= 0) {
        return;
    }

    const snapshot = projection.workspaces;
    const current = (if (activeId(projection)) |id| snapshot.indexOf(id) else null) orelse return pills.activeWorkspace(canvas);
    // Native visibility follows available space, including after a reconnect
    // restores the TUI's collapsed workspace preference.
    var window = WorkspaceWindow.centered(snapshot.count, current, 3);
    const gap = canvas.chrome.px(logical_gap);
    const counter = canvas.chrome.px(counter_width);
    const minimum = canvas.chrome.px(minimum_width);
    const visible: f32 = @floatFromInt(window.count);
    const overflow = if (window.count < window.total) 2 * (counter + gap) else 0;
    if (pills.area.width < visible * minimum + (visible - 1) * gap + overflow) {
        window = WorkspaceWindow.centered(snapshot.count, current, 1);
    }

    const counters = window.count < window.total and pills.area.width >= minimum + 2 * (counter + gap);
    const offset: usize = if (counters) 1 else 0;
    const length = window.count + 2 * offset;
    var children: [5]Item = @splat(.{ .maximum = .{ canvas.chrome.px(maximum_width), 65535 } });
    if (counters) {
        children[0] = .{ .width = .{ .fixed = counter } };
        children[length - 1] = .{ .width = .{ .fixed = counter } };
    }

    try (Layout{ .area = pills.area, .gap = gap }).resolve(children[0..length]);
    if (counters) {
        if (window.previous()) |index| {
            const counter_widget: WorkspacePills = .{ .context = pills.context, .area = children[0].bounds };
            try counter_widget.overflowCounter(canvas, .{ 0, index + 1 });
        }
    }

    for (0..window.count) |index| {
        const workspace_widget: WorkspacePills = .{ .context = pills.context, .area = children[offset + index].bounds };
        try workspace_widget.workspace(canvas, window.first + index);
    }

    if (counters) {
        if (window.next()) |index| {
            const counter_widget: WorkspacePills = .{ .context = pills.context, .area = children[length - 1].bounds };
            try counter_widget.overflowCounter(canvas, .{ index, snapshot.count });
        }
    }
}

fn activeWorkspace(pills: WorkspacePills, canvas: *Canvas) !void {
    const tabs = pills.context.projection.tabs;
    var storage: [64]u8 = undefined;
    const name_value = tabs.displayedWorkspaceName();
    const text = if (name_value.len != 0) name_value else if (tabs.workspace) |location| switch (location) {
        .workspace => |id| std.fmt.bufPrint(&storage, "workspace {d}", .{@intFromEnum(id)}) catch unreachable,
        .worktree => |id| std.fmt.bufPrint(&storage, "worktree {d}", .{@intFromEnum(id)}) catch unreachable,
    } else "workspace";
    const label: Label = .{ .text = text, .color = canvas.theme.palette.text, .bold = true, .face = .sans, .size = .body };
    _ = try canvas.textAt(pills.area, label);
}

fn workspace(pills: WorkspacePills, canvas: *Canvas, index: usize) !void {
    var storage: [core.max_workspace_name_bytes + 8]u8 = undefined;
    const text = pills.labelText(&storage, index);
    const id = pills.context.projection.workspaces.workspaceAt(index);
    const button: PixelButton = .{
        .context = pills.context,
        .area = pills.area,
        .intent = .{ .select_workspace = id },
        .text = text,
        .active = activeId(pills.context.projection) == id,
        .alignment = .center,
        .inset = canvas.chrome.px(inset),
        .dot = attention.workspaceDot(pills.context.projection, canvas.theme.palette, id),
    };
    try button.draw(canvas);
}

fn overflowCounter(pills: WorkspacePills, canvas: *Canvas, range: [2]usize) !void {
    const previous = range[0] == 0;
    const index = if (previous) range[1] - 1 else range[0];
    const total = range[1] - range[0];
    var storage: [16]u8 = undefined;
    const text = if (previous)
        std.fmt.bufPrint(&storage, "‹{d}", .{total}) catch unreachable
    else
        std.fmt.bufPrint(&storage, "{d}›", .{total}) catch unreachable;
    const button: PixelButton = .{
        .context = pills.context,
        .area = pills.area,
        .intent = .{ .select_workspace = pills.context.projection.workspaces.workspaceAt(index) },
        .text = text,
        .alignment = .center,
        .background = false,
        .inset = canvas.chrome.px(2),
        .dot = pills.hiddenDot(canvas, range),
    };
    try button.draw(canvas);
}

fn hiddenDot(pills: WorkspacePills, canvas: *const Canvas, range: [2]usize) ?core.Color {
    const projection = pills.context.projection;
    var urgent: ?*const client.Agent = null;
    for (projection.agents.slice()) |*agent| {
        if (!attention.needsInput(agent.status)) {
            continue;
        }

        const id = switch (agent.location.workspace) {
            .workspace => |id| id,
            .worktree => continue,
        };
        const index = projection.workspaces.indexOf(id) orelse continue;
        if (index < range[0] or index >= range[1]) {
            continue;
        }

        if (urgent == null or client.agent_attention.compare(agent, urgent.?) == .lt) {
            urgent = agent;
        }
    }

    return if (urgent) |agent| attention.statusColor(canvas.theme.palette, agent.status) else null;
}

fn labelText(pills: WorkspacePills, storage: []u8, index: usize) []const u8 {
    return std.fmt.bufPrint(storage, "{d} {s}", .{ index + 1, pills.name(index) }) catch unreachable;
}

fn name(pills: WorkspacePills, index: usize) []const u8 {
    const projection = pills.context.projection;
    if (activeId(projection) == projection.workspaces.workspaceAt(index)) {
        const current = projection.tabs.displayedWorkspaceName();
        if (current.len != 0) {
            return current;
        }
    }

    return projection.workspaces.nameAt(index);
}

/// The workspace the tabs model currently shows, if it is not a worktree.
/// Example: `const active = WorkspacePills.activeId(projection);`
pub fn activeId(projection: *const client.Projection) ?core.WorkspaceId {
    const location = projection.tabs.workspace orelse return null;
    return switch (location) {
        .workspace => |id| id,
        .worktree => null,
    };
}

const logical_gap: f32 = 6;
const counter_width: f32 = 40;
const minimum_width: f32 = 56;
const maximum_width: f32 = 96;
const inset: f32 = 8;
