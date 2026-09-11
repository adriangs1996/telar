const ArrivalCapture = @This();
const client_model = @import("../../root.zig").model;
const WorkspaceArrivalDelivery = @import("WorkspaceArrivalDelivery.zig");
const std = @import("std");
model: *const client_model.Model,
expected_before: client_model.Version = .{},
calls: usize = 0,
observed_commit: bool = false,
fail: bool = false,

pub fn port(capture: *ArrivalCapture) WorkspaceArrivalDelivery {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, activation: client_model.WorkspaceActivation) !void {
    const capture: *ArrivalCapture = @ptrCast(@alignCast(context));
    const version = capture.model.version();
    capture.calls += 1;
    capture.observed_commit = std.meta.eql(capture.model.activeTabLocation().?, activation.location) and
        version.workspace == activation.workspace_revision and
        version.tabs == activation.tabs_revision and
        version.active_tab == activation.active_tab_revision and
        version.panes == activation.panes_revision and
        version.copy == activation.copy_revision and
        activation.workspace_revision_before == capture.expected_before.workspace and
        activation.tabs_revision_before == capture.expected_before.tabs and
        activation.active_tab_revision_before == capture.expected_before.active_tab and
        activation.panes_revision_before == capture.expected_before.panes and
        activation.copy_revision_before == capture.expected_before.copy and
        activation.workspace_revision_before +% 1 == activation.workspace_revision and
        activation.tabs_revision_before +% 1 == activation.tabs_revision and
        activation.active_tab_revision_before +% 1 == activation.active_tab_revision and
        activation.panes_revision_before +% 1 == activation.panes_revision and
        activation.copy_revision_before +% @intFromBool(activation.copy_released) == activation.copy_revision;
    if (capture.fail) {
        return error.ArrivalDeliveryFailed;
    }
}
