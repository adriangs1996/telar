const DeliveryCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("create_tab.zig");
const ConfirmationDelivery = @import("ConfirmationDelivery.zig");
const std = @import("std");
model: *client_model.Model,
expected: source_namespace.schema.TabLocation,
calls: usize = 0,
observed_commit: bool = false,
fail: bool = false,

pub fn port(capture: *DeliveryCapture) ConfirmationDelivery {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, creation: client_model.TabCreation) !void {
    const capture: *DeliveryCapture = @ptrCast(@alignCast(context));
    const version = capture.model.version();
    const previous = capture.model.workspace.find(creation.previous.tab_id);
    const created = capture.model.workspace.find(creation.created.tab_id);
    capture.calls += 1;
    capture.observed_commit = std.meta.eql(capture.model.activeTabLocation(), capture.expected) and
        capture.model.workspace.count == 2 and
        std.meta.eql(creation.created, capture.expected) and
        previous != null and
        created != null and
        previous.?.model.layout.currentRevision() == creation.previous_layout_revision and
        created.?.model.layout.currentRevision() == creation.created_layout_revision and
        created.?.model.findConst(creation.created_root_pane_id) != null and
        version.workspace == creation.workspace_revision and
        version.tabs == creation.tabs_revision and
        version.active_tab == creation.active_tab_revision and
        version.panes == creation.panes_revision and
        version.copy == creation.copy_revision and
        creation.tabs_revision_before +% 1 == creation.tabs_revision and
        creation.active_tab_revision_before +% 1 == creation.active_tab_revision and
        creation.copy_revision_before +% @intFromBool(creation.copy_released) == creation.copy_revision;

    if (capture.fail) {
        return error.CreationSyncFailed;
    }
}
