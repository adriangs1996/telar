const RemovalCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("close_tab.zig");
const RemovalDelivery = @import("RemovalDelivery.zig");
model: *const client_model.Model,
calls: usize = 0,
commit: ?client_model.TabRemovalCommit = null,
previous_workspace: ?source_namespace.schema.WorkspaceId = null,
directive: source_namespace.TabRemovalDirective = .continue_running,
observed_commit: bool = false,
failure: ?anyerror = null,

pub fn port(capture: *RemovalCapture) RemovalDelivery {
    return .{
        .context = capture,
        .deliver = deliver,
    };
}

fn deliver(context: *anyopaque, commit: client_model.TabRemovalCommit, previous_workspace: ?source_namespace.schema.WorkspaceId) !source_namespace.TabRemovalDirective {
    const capture: *RemovalCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.commit = commit;
    capture.previous_workspace = previous_workspace;
    capture.observed_commit = capture.observesCommit(commit);
    if (capture.failure) |failure| {
        return failure;
    }

    return capture.directive;
}

fn observesCommit(capture: *const RemovalCapture, commit: client_model.TabRemovalCommit) bool {
    const version = capture.model.version();
    return switch (commit) {
        .removed => |removal| capture.model.tabLocation(removal.removed.tab_id) == null and
            (capture.model.workspaceLocation() == null) == removal.workspace_removed and
            version.workspace == removal.workspace_revision and
            version.tabs == removal.tabs_revision and
            version.active_tab == removal.active_tab_revision and
            version.panes == removal.panes_revision and
            version.copy == removal.copy_revision,
        .stale => |stale| version.workspace == stale.workspace_revision and
            version.tabs == stale.tabs_revision and
            version.active_tab == stale.active_tab_revision and
            version.panes == stale.panes_revision and
            version.copy == stale.copy_revision,
    };
}
