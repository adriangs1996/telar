const id = @import("../id.zig");
const TabLocationType = @import("../TabLocation.zig");
const workspace = @import("workspace.zig");
const TabClosed = @This();

/// `.none` identifies a lifecycle event emitted by the runtime rather than
/// the response to an explicit close request.
request_id: id.RequestId,
location: TabLocationType,
workspace_closed: bool,
/// Canonical predecessor in the runtime's workspace order. Present only
/// when this close removed the workspace and another workspace survives.
previous_workspace: ?id.WorkspaceId = null,

pub const wire_allow_zero_request_id = true;

pub fn validateWire(message: TabClosed) !void {
    try workspace.validateWorkspaceClosure(
        message.location.workspace,
        message.workspace_closed,
        message.previous_workspace,
    );
}
