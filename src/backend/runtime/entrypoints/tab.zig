//! Tab lifecycle external message entrypoints.

const core = @import("telar-core");
const pane_mod = @import("../../pane/root.zig");
const workspace_mod = @import("../../workspace/root.zig");
const common = @import("common.zig");

const PaneStore = pane_mod.PaneStore;
const WorkspaceRepository = workspace_mod.Repository;
const schema = core.schema;

pub const RequestTabSnapshotContext = struct {
    panes: *PaneStore,
    workspaces: *WorkspaceRepository,
    responses: *common.ResponseQueue,
};

pub fn requestTabSnapshot(context: RequestTabSnapshotContext, request: schema.RequestTabSnapshot) !void {
    if (!context.workspaces.reader().contains(request.location) or context.panes.countAt(request.location) == 0) {
        try common.queueFailure(context.responses, request.request_id, .tab_not_found, "tab not found");
        return;
    }

    try context.responses.push(.{ .tab_snapshot = .{
        .request_id = request.request_id,
        .location = request.location,
    } });
}
