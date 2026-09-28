//! Disposable scroll bounds and attention order, independent of frame widgets.
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const SnapshotMark = @import("SnapshotMark.zig");
const PixelScroll = @import("PixelScroll.zig");
const SidebarState = @This();

agents: PixelScroll = .{},
projects: PixelScroll = .{},
active_workspace: ?core.WorkspaceLocation = null,
active_position: ?usize = null,
project_height: f32 = 0,
project_pitch: f32 = 0,
order: [core.max_agent_snapshot_entries]u8 = undefined,
order_len: u8 = 0,
fleet: [core.max_agent_snapshot_entries]client.FleetEntry = undefined,
ordered: SnapshotMark = .{},
ordered_workspaces: u64 = 0,
ordered_focus: ?core.PaneId = null,

/// Orders the fleet only when the agents, the workspace list or the focused
/// pane changed, retaining indices rather than borrowed agents.
/// Example: `state.observe(projection);`
pub fn observe(self: *SidebarState, projection: *const client.Projection) void {
    const snapshot = projection.agents;
    const mark = SnapshotMark.of(snapshot);
    const focused = focusedPane(projection);
    if (self.ordered.eql(mark) and self.ordered_workspaces == projection.workspaces.revision and self.ordered_focus == focused) {
        return;
    }

    const fleet = client.fleet_order.order(.{
        .agents = snapshot.slice(),
        .workspaces = projection.workspaces,
        .focused = focused,
    }, &self.fleet);
    self.order_len = @intCast(fleet.len);
    for (fleet, 0..) |entry, position| {
        self.order[position] = entry.index;
    }

    self.ordered = mark;
    self.ordered_workspaces = projection.workspaces.revision;
    self.ordered_focus = focused;
}

/// The fleet entries of the last observed snapshot, in drawing order.
/// Example: `for (state.entries()) |entry| { ... }`
pub fn entries(self: *const SidebarState) []const client.FleetEntry {
    return self.fleet[0..self.order_len];
}

fn focusedPane(projection: *const client.Projection) ?core.PaneId {
    const tab = projection.tab orelse return null;
    return projection.model.tabs.layout[tab].focused();
}

/// Disables both viewports until another frame lays them out.
/// Example: `state.hide();`
pub fn hide(self: *SidebarState) void {
    self.agents.hide();
    self.projects.hide();
    self.project_height = 0;
}

/// Reveals a new workspace or resized row, retaining manual scrolling otherwise.
/// Example: `state.revealWorkspace(projection, list.height);`
pub fn revealWorkspace(self: *SidebarState, projection: *const client.Projection, height: f32) void {
    const location = projection.model.workspace;
    const position = if (location) |value| switch (value) {
        .workspace => |id| projection.workspaces.indexOf(projection.workspaces.projectOf(id)),
        .worktree => null,
    } else null;
    const pitch: f32 = @floatFromInt(self.projects.step);
    const changed = !std.meta.eql(self.active_workspace, location) or self.active_position != position or self.project_height != height or self.project_pitch != pitch;
    self.active_workspace = location;
    self.active_position = position;
    self.project_height = height;
    self.project_pitch = pitch;
    if (!changed) {
        return;
    }

    if (position) |index| {
        const top = @as(f32, @floatFromInt(index)) * pitch;
        self.projects.reveal(.{ top, top + pitch }, height);
    }
}

/// The attention order of the last observed snapshot, as replica indices.
/// Example: `for (state.ordering()) |index| { ... }`
pub fn ordering(self: *const SidebarState) []const u8 {
    return self.order[0..self.order_len];
}

