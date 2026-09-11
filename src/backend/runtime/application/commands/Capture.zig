const PaneDetachedType = @import("../../attachment/PaneDetached.zig");
const detach_pane = @import("detach_pane.zig");
const PaneIdType = @import("telar-core").PaneId;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const Attachments = @import("Attachments.zig");
const DetachPaneGeometryLease = @import("DetachPaneGeometryLease.zig");
const std = @import("std");
const Capture = @This();

detached: ?PaneDetachedType = null,
effects: [3]detach_pane.Effect = undefined,
effect_count: usize = 0,
requested_pane: PaneIdType = .invalid,
released_workspace: ?WorkspaceLocationType = null,
leave_allowed: bool = true,

pub fn attachments(capture: *Capture) Attachments {
    return .{
        .context = capture,
        .detach = detach,
        .leave_workspace = leaveWorkspace,
    };
}

pub fn geometry(capture: *Capture) DetachPaneGeometryLease {
    return .{ .context = capture, .release = release };
}

fn detach(context: *anyopaque, pane_id: PaneIdType) ?PaneDetachedType {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.record(.detach);
    capture.requested_pane = pane_id;
    return capture.detached;
}

fn release(context: *anyopaque, workspace: WorkspaceLocationType) void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.record(.release);
    capture.released_workspace = workspace;
}

fn leaveWorkspace(context: *anyopaque, workspace: WorkspaceLocationType) bool {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.record(.leave_workspace);
    return capture.leave_allowed and capture.detached != null and std.meta.eql(capture.detached.?.workspace, workspace);
}

fn record(capture: *Capture, effect: detach_pane.Effect) void {
    capture.effects[capture.effect_count] = effect;
    capture.effect_count += 1;
}
