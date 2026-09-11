const Capture = @This();
const attachment_mod = @import("../../attachment/root.zig");
const source_namespace = @import("detach_pane.zig");
const Attachments = @import("Attachments.zig");
const GeometryLease = @import("DetachPaneGeometryLease.zig");
const std = @import("std");
detached: ?attachment_mod.PaneDetached = null,
effects: [3]source_namespace.Effect = undefined,
effect_count: usize = 0,
requested_pane: source_namespace.schema.PaneId = .invalid,
released_workspace: ?source_namespace.schema.WorkspaceLocation = null,
leave_allowed: bool = true,

pub fn attachments(capture: *Capture) Attachments {
    return .{
        .context = capture,
        .detach = detach,
        .leave_workspace = leaveWorkspace,
    };
}

pub fn geometry(capture: *Capture) GeometryLease {
    return .{ .context = capture, .release = release };
}

fn detach(context: *anyopaque, pane_id: source_namespace.schema.PaneId) ?attachment_mod.PaneDetached {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.record(.detach);
    capture.requested_pane = pane_id;
    return capture.detached;
}

fn release(context: *anyopaque, workspace: source_namespace.schema.WorkspaceLocation) void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.record(.release);
    capture.released_workspace = workspace;
}

fn leaveWorkspace(context: *anyopaque, workspace: source_namespace.schema.WorkspaceLocation) bool {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.record(.leave_workspace);
    return capture.leave_allowed and capture.detached != null and std.meta.eql(capture.detached.?.workspace, workspace);
}

fn record(capture: *Capture, effect: source_namespace.Effect) void {
    capture.effects[capture.effect_count] = effect;
    capture.effect_count += 1;
}
