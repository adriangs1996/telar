//! Vertical contract test for the runtime detach-pane flow.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../attachment/root.zig");
const detach_pane_commands = @import("../application/commands/detach_pane.zig");
const detach_pane_controller = @import("../entrypoints/requests/detach_pane.zig");

const schema = core.schema;

const Effects = struct {
    detached: attachment_mod.PaneDetached,
    attachment_committed: bool = false,
    workspace_left: bool = false,
    geometry_released: bool = false,
    stale_count: usize = 0,

    fn attachments(effects: *Effects) detach_pane_commands.Attachments {
        return .{
            .context = effects,
            .detach = detach,
            .leave_workspace = leaveWorkspace,
        };
    }

    fn geometry(effects: *Effects) detach_pane_commands.GeometryLease {
        return .{ .context = effects, .release = release };
    }

    fn staleMessages(effects: *Effects) detach_pane_controller.StaleMessages {
        return .{ .context = effects, .record = recordStale };
    }

    fn detach(context: *anyopaque, pane_id: schema.PaneId) ?attachment_mod.PaneDetached {
        const effects: *Effects = @ptrCast(@alignCast(context));
        std.debug.assert(pane_id == effects.detached.pane_id);
        effects.attachment_committed = true;
        return effects.detached;
    }

    fn release(context: *anyopaque, workspace: schema.WorkspaceLocation) void {
        const effects: *Effects = @ptrCast(@alignCast(context));
        std.debug.assert(effects.workspace_left);
        std.debug.assert(std.meta.eql(workspace, effects.detached.workspace));
        effects.geometry_released = true;
    }

    fn leaveWorkspace(context: *anyopaque, workspace: schema.WorkspaceLocation) bool {
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
};

test "a detach request commits session state before releasing geometry" {
    const pane_id = try schema.id.pane(7);
    var effects: Effects = .{ .detached = .{
        .pane_id = pane_id,
        .workspace = .{ .workspace = try schema.id.workspace(3) },
        .last_attachment = true,
    } };
    var handler: detach_pane_commands.DetachPaneHandler = .{
        .attachments = effects.attachments(),
        .geometry = effects.geometry(),
    };
    var controller = detach_pane_controller.Controller.init(handler.executor(), effects.staleMessages());

    try controller.detachPane(.{ .pane_id = pane_id });

    try std.testing.expect(effects.attachment_committed);
    try std.testing.expect(effects.workspace_left);
    try std.testing.expect(effects.geometry_released);
    try std.testing.expectEqual(@as(usize, 0), effects.stale_count);
}
