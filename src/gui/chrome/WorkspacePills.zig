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
const WorkspacePills = @This();

context: *Context,
area: Rect,

/// Logical width of the three-workspace area, independent of label lengths.
pub const preferred_width: f32 = 320;

/// Paints within the parent's fixed reservation and returns the pixels used.
/// Example: `const used = try pills.paint();`
pub fn paint(pills: WorkspacePills) !f32 {
    const projection = pills.context.projection;
    const canvas = pills.context.canvas;
    if (pills.area.width <= 0 or pills.area.height <= 0) {
        return 0;
    }

    const snapshot = projection.workspaces;
    const current = (if (activeId(projection)) |id| snapshot.indexOf(id) else null) orelse return pills.paintCurrent();
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
            try pills.drawCounter(children[0].bounds, .{ 0, index + 1 });
        }
    }

    for (0..window.count) |index| {
        try pills.draw(children[offset + index].bounds, window.first + index);
    }

    if (counters) {
        if (window.next()) |index| {
            try pills.drawCounter(children[length - 1].bounds, .{ index, snapshot.count });
        }
    }

    const last = children[length - 1].bounds;
    return last.x + last.width - pills.area.x;
}

fn paintCurrent(pills: WorkspacePills) !f32 {
    const tabs = pills.context.projection.tabs;
    const canvas = pills.context.canvas;
    var storage: [64]u8 = undefined;
    const name_value = tabs.displayedWorkspaceName();
    const text = if (name_value.len != 0) name_value else if (tabs.workspace) |location| switch (location) {
        .workspace => |id| std.fmt.bufPrint(&storage, "workspace {d}", .{@intFromEnum(id)}) catch unreachable,
        .worktree => |id| std.fmt.bufPrint(&storage, "worktree {d}", .{@intFromEnum(id)}) catch unreachable,
    } else "workspace";
    const label: Label = .{ .text = text, .color = canvas.theme.palette.text, .bold = true, .face = .sans, .size = .body };
    return canvas.textAt(pills.area, label);
}

fn draw(pills: WorkspacePills, room: Rect, index: usize) !void {
    var storage: [core.max_workspace_name_bytes + 8]u8 = undefined;
    const text = pills.labelText(&storage, index);
    const id = pills.context.projection.workspaces.workspaceAt(index);
    try pills.context.pill(.{
        .area = room,
        .intent = .{ .select_workspace = id },
        .text = text,
        .active = activeId(pills.context.projection) == id,
        .inset = pills.context.canvas.chrome.px(inset),
        .dot = attention.workspaceDot(pills.context.projection, pills.context.canvas.theme.palette, id),
    });
}

fn drawCounter(pills: WorkspacePills, room: Rect, range: [2]usize) !void {
    const previous = range[0] == 0;
    const index = if (previous) range[1] - 1 else range[0];
    const total = range[1] - range[0];
    var storage: [16]u8 = undefined;
    const text = if (previous)
        std.fmt.bufPrint(&storage, "‹{d}", .{total}) catch unreachable
    else
        std.fmt.bufPrint(&storage, "{d}›", .{total}) catch unreachable;
    try pills.context.pill(.{
        .area = room,
        .intent = .{ .select_workspace = pills.context.projection.workspaces.workspaceAt(index) },
        .text = text,
        .inset = pills.context.canvas.chrome.px(2),
        .dot = pills.hiddenDot(range),
    });
}

fn hiddenDot(pills: WorkspacePills, range: [2]usize) ?core.Color {
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

    return if (urgent) |agent| attention.statusColor(pills.context.canvas.theme.palette, agent.status) else null;
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
