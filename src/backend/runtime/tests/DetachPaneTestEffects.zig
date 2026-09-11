const Effects = @This();
const attachment_mod = @import("../attachment/root.zig");
const detach_pane_commands = @import("../application/commands/detach_pane.zig");
const detach_pane_controller = @import("../entrypoints/requests/detach_pane.zig");
const source_namespace = @import("detach_pane_test.zig");
const std = @import("std");
detached: attachment_mod.PaneDetached,
attachment_committed: bool = false,
workspace_left: bool = false,
geometry_released: bool = false,
stale_count: usize = 0,

pub fn attachments(effects: *Effects) detach_pane_commands.Attachments {
    return .{
        .context = effects,
        .detach = detach,
        .leave_workspace = leaveWorkspace,
    };
}

pub fn geometry(effects: *Effects) detach_pane_commands.GeometryLease {
    return .{ .context = effects, .release = release };
}

pub fn staleMessages(effects: *Effects) detach_pane_controller.StaleMessages {
    return .{ .context = effects, .record = recordStale };
}

fn detach(context: *anyopaque, pane_id: source_namespace.schema.PaneId) ?attachment_mod.PaneDetached {
    const effects: *Effects = @ptrCast(@alignCast(context));
    std.debug.assert(pane_id == effects.detached.pane_id);
    effects.attachment_committed = true;
    return effects.detached;
}

fn release(context: *anyopaque, workspace: source_namespace.schema.WorkspaceLocation) void {
    const effects: *Effects = @ptrCast(@alignCast(context));
    std.debug.assert(effects.workspace_left);
    std.debug.assert(std.meta.eql(workspace, effects.detached.workspace));
    effects.geometry_released = true;
}

fn leaveWorkspace(context: *anyopaque, workspace: source_namespace.schema.WorkspaceLocation) bool {
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
