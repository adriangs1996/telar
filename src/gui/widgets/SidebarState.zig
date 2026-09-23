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
ordered: SnapshotMark = .{},

/// Sorts only when the snapshot identity changes, retaining indices rather
/// than borrowed agents. Example: `state.observe(projection.agents);`
pub fn observe(self: *SidebarState, snapshot: *const data.AgentSnapshot) void {
    const mark = SnapshotMark.of(snapshot);
    if (self.ordered.eql(mark)) {
        return;
    }

    const agents = snapshot.slice();
    self.order_len = @intCast(@min(agents.len, self.order.len));
    for (self.order[0..self.order_len], 0..) |*slot, index| {
        slot.* = @intCast(index);
    }

    std.sort.pdq(u8, self.order[0..self.order_len], agents, indexLessThan);
    self.ordered = mark;
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
        .workspace => |id| projection.workspaces.indexOf(id),
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

fn indexLessThan(agents: []const data.Agent, left: u8, right: u8) bool {
    return client.agent_attention.lessThan({}, &agents[left], &agents[right]);
}
