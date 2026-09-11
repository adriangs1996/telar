const PaneDetachedType = @import("../attachment/PaneDetached.zig");
const AttachmentsType = @import("../application/commands/Attachments.zig");
const DetachPaneGeometryLease = @import("../application/commands/DetachPaneGeometryLease.zig");
const StaleMessagesType = @import("../entrypoints/requests/StaleMessages.zig");
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const Effects = @This();

detached: PaneDetachedType,
attachment_committed: bool = false,
workspace_left: bool = false,
geometry_released: bool = false,
stale_count: usize = 0,

pub fn attachments(effects: *Effects) AttachmentsType {
    return .{
        .context = effects,
        .detach = detach,
        .leave_workspace = leaveWorkspace,
    };
}

pub fn geometry(effects: *Effects) DetachPaneGeometryLease {
    return .{ .context = effects, .release = release };
}

pub fn staleMessages(effects: *Effects) StaleMessagesType {
    return .{ .context = effects, .record = recordStale };
}

fn detach(context: *anyopaque, pane_id: PaneIdType) ?PaneDetachedType {
    const effects: *Effects = @ptrCast(@alignCast(context));
    std.debug.assert(pane_id == effects.detached.pane_id);
    effects.attachment_committed = true;
    return effects.detached;
}

fn release(context: *anyopaque, workspace: WorkspaceLocationType) void {
    const effects: *Effects = @ptrCast(@alignCast(context));
    std.debug.assert(effects.workspace_left);
    std.debug.assert(std.meta.eql(workspace, effects.detached.workspace));
    effects.geometry_released = true;
}

fn leaveWorkspace(context: *anyopaque, workspace: WorkspaceLocationType) bool {
    const effects: *Effects = @ptrCast(@alignCast(context));
    std.debug.assert(effects.attachment_committed);
    std.debug.assert(std.meta.eql(workspace, effects.detached.workspace));
    effects.workspace_left = true;
    return true;
}

fn recordStale(context: *anyopaque) void {
    const effects: *Effects = @ptrCast(@alignCast(context));
    effects.stale_count += 1;
}
