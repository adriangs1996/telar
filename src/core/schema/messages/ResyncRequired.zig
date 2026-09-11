const ResyncRequired = @This();
const source_namespace = @import("workspace.zig");
workspace: source_namespace.WorkspaceLocation,
workspace_closed: bool,
previous_workspace: ?source_namespace.WorkspaceId = null,

pub fn validateWire(message: ResyncRequired) !void {
    try source_namespace.validateWorkspaceClosure(
        message.workspace,
        message.workspace_closed,
        message.previous_workspace,
    );
}
