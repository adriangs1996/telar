const TabClosed = @This();
const source_namespace = @import("tab.zig");
const workspace = @import("workspace.zig");
/// `.none` identifies a lifecycle event emitted by the runtime rather than
/// the response to an explicit close request.
request_id: source_namespace.RequestId,
location: source_namespace.TabLocation,
workspace_closed: bool,
/// Canonical predecessor in the runtime's workspace order. Present only
/// when this close removed the workspace and another workspace survives.
previous_workspace: ?source_namespace.WorkspaceId = null,

pub const wire_allow_zero_request_id = true;

pub fn validateWire(message: TabClosed) !void {
    try workspace.validateWorkspaceClosure(
        message.location.workspace,
        message.workspace_closed,
        message.previous_workspace,
    );
}
