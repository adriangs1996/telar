//! Disposable scroll bounds and attention order, independent of frame widgets.
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
pub fn observe(state: *SidebarState, snapshot: *const client.AgentSnapshot) void {
    const mark = SnapshotMark.of(snapshot);
    if (state.ordered.eql(mark)) {
        return;
    }

    const agents = snapshot.slice();
    state.order_len = @intCast(@min(agents.len, state.order.len));
    for (state.order[0..state.order_len], 0..) |*slot, index| {
        slot.* = @intCast(index);
    }

    std.sort.pdq(u8, state.order[0..state.order_len], agents, indexLessThan);
    state.ordered = mark;
}

/// Disables both viewports until another frame lays them out.
/// Example: `state.hide();`
pub fn hide(state: *SidebarState) void {
    state.agents.hide();
    state.projects.hide();
    state.project_height = 0;
}

/// Reveals a new workspace or resized row, retaining manual scrolling otherwise.
/// Example: `state.revealWorkspace(projection, list.height);`
pub fn revealWorkspace(state: *SidebarState, projection: *const client.Projection, height: f32) void {
    const location = projection.tabs.workspace;
    const position = if (location) |value| switch (value) {
        .workspace => |id| projection.workspaces.indexOf(id),
        .worktree => null,
    } else null;
    const pitch: f32 = @floatFromInt(state.projects.step);
    const changed = !std.meta.eql(state.active_workspace, location) or state.active_position != position or state.project_height != height or state.project_pitch != pitch;
    state.active_workspace = location;
    state.active_position = position;
    state.project_height = height;
    state.project_pitch = pitch;
    if (!changed) {
        return;
    }

    if (position) |index| {
        const top = @as(f32, @floatFromInt(index)) * pitch;
        state.projects.reveal(.{ top, top + pitch }, height);
    }
}

/// The attention order of the last observed snapshot, as replica indices.
/// Example: `for (state.ordering()) |index| { ... }`
pub fn ordering(state: *const SidebarState) []const u8 {
    return state.order[0..state.order_len];
}

fn indexLessThan(agents: []const client.Agent, left: u8, right: u8) bool {
    return client.agent_attention.lessThan({}, &agents[left], &agents[right]);
}
