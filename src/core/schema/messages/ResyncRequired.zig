const types = @import("../types.zig");
const id = @import("../id.zig");
const workspace_ops = @import("workspace.zig");
const ResyncRequired = @This();

workspace: types.WorkspaceLocation,
workspace_closed: bool,
previous_workspace: ?id.WorkspaceId = null,

pub fn validateWire(message: ResyncRequired) !void {
    try workspace_ops.validateWorkspaceClosure(
        message.workspace,
        message.workspace_closed,
        message.previous_workspace,
    );
}
