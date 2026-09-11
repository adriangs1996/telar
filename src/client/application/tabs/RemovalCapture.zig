const ModelType = @import("../../model/Model.zig");
const types = @import("../../model/types.zig");
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const close_tab = @import("close_tab.zig");
const RemovalDelivery = @import("RemovalDelivery.zig");
const RemovalCapture = @This();

model: *const ModelType,
calls: usize = 0,
commit: ?types.TabRemovalCommit = null,
previous_workspace: ?WorkspaceIdType = null,
directive: close_tab.TabRemovalDirective = .continue_running,
observed_commit: bool = false,
failure: ?anyerror = null,

pub fn port(capture: *RemovalCapture) RemovalDelivery {
    return .{
        .context = capture,
        .deliver = deliver,
    };
}

fn deliver(context: *anyopaque, commit: types.TabRemovalCommit, previous_workspace: ?WorkspaceIdType) !close_tab.TabRemovalDirective {
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

fn observesCommit(capture: *const RemovalCapture, commit: types.TabRemovalCommit) bool {
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
