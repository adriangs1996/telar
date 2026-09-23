const types = @import("../types.zig");
const id = @import("../id.zig");
const workspace_ops = @import("workspace.zig");
const ResyncRequired = @This();

workspace: types.WorkspaceLocation,
workspace_closed: bool,
previous_workspace: ?id.WorkspaceId = null,

pub fn validateWire(self: ResyncRequired) !void {
    try workspace_ops.validateWorkspaceClosure(
        self.workspace,
        self.workspace_closed,
        self.previous_workspace,
    );
}
