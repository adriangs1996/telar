const ModelType = @import("../../model/Model.zig");
const PaneIdType = @import("telar-core").PaneId;
const CreateWorkspaceOperationGate = @import("CreateWorkspaceOperationGate.zig");
const CreationRequestEffects = @import("CreationRequestEffects.zig");
const RequestWorkspaceCreation = @import("RequestWorkspaceCreation.zig");
const create_workspace = @import("create_workspace.zig");
const RequestWorkspaceCreationHandler = @This();

model: *const ModelType,
gate: CreateWorkspaceOperationGate,
effects: CreationRequestEffects,

/// Sends one creation intent. Without an explicit directory the attached
/// focused pane supplies it; a blocked or stale request returns false
/// without effects or semantic mutation.
///
/// ```zig
/// if (!try handler.execute(.{ .name = "agents", .cwd = "/work/agents" })) return;
/// ```
pub fn execute(handler: *RequestWorkspaceCreationHandler, command: RequestWorkspaceCreation) !bool {
    if (handler.gate.pending(handler.gate.context)) {
        return false;
    }

    try create_workspace.validateName(command.name);
    const cwd_source: ?PaneIdType = if (command.cwd.len == 0)
        handler.model.planWorkspaceCreation() orelse return false
    else
        null;
    try handler.effects.send(handler.effects.context, .{
        .name = command.name,
        .cwd = command.cwd,
        .cwd_source = cwd_source,
        .create_cwd = command.create_cwd,
    });

    return true;
}
