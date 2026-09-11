const DeliveryCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("create_workspace.zig");
const WorkspaceCreationDelivery = @import("WorkspaceCreationDelivery.zig");
const std = @import("std");
model: *const client_model.Model,
expected: source_namespace.schema.TabLocation,
calls: usize = 0,
observed_commit: bool = false,
fail: bool = false,

pub fn delivery(capture: *DeliveryCapture) WorkspaceCreationDelivery {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, replacement: *const client_model.WorkspaceReplacement) !void {
    const capture: *DeliveryCapture = @ptrCast(@alignCast(context));
    const version = capture.model.version();
    capture.calls += 1;
    capture.observed_commit = std.meta.eql(capture.model.activeTabLocation(), capture.expected) and
        std.meta.eql(replacement.activation.location, capture.expected) and
        replacement.departure.source != null and
        version.workspace == replacement.activation.workspace_revision and
        version.tabs == replacement.activation.tabs_revision and
        version.active_tab == replacement.activation.active_tab_revision and
        version.panes == replacement.activation.panes_revision and
        version.copy == replacement.activation.copy_revision and
        replacement.activation.workspace_revision_before +% 1 == replacement.activation.workspace_revision and
        replacement.activation.tabs_revision_before +% 1 == replacement.activation.tabs_revision and
        replacement.activation.active_tab_revision_before +% 1 == replacement.activation.active_tab_revision and
        replacement.activation.panes_revision_before +% 1 == replacement.activation.panes_revision and
        replacement.activation.copy_revision_before +% @intFromBool(replacement.activation.copy_released) == replacement.activation.copy_revision;

    if (capture.fail) {
        return error.CreationSyncFailed;
    }
}
