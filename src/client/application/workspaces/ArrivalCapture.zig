const ModelType = @import("../../model/Model.zig");
const VersionType = @import("../../model/Version.zig");
const WorkspaceArrivalDelivery = @import("WorkspaceArrivalDelivery.zig");
const WorkspaceActivationType = @import("../../model/WorkspaceActivation.zig");
const std = @import("std");
const ArrivalCapture = @This();

model: *const ModelType,
expected_before: VersionType = .{},
calls: usize = 0,
observed_commit: bool = false,
fail: bool = false,

pub fn port(capture: *ArrivalCapture) WorkspaceArrivalDelivery {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, activation: WorkspaceActivationType) !void {
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
