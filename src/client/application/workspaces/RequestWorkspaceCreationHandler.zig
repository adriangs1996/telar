const ModelType = @import("../../model/Model.zig");
const CreateWorkspaceOperationGate = @import("CreateWorkspaceOperationGate.zig");
const CreationRequestEffects = @import("CreationRequestEffects.zig");
const RequestWorkspaceCreation = @import("RequestWorkspaceCreation.zig");
const create_workspace = @import("create_workspace.zig");
const RequestWorkspaceCreationHandler = @This();

model: *const ModelType,
gate: CreateWorkspaceOperationGate,
effects: CreationRequestEffects,

/// Sends one creation intent from the attached focused pane. A blocked or
/// stale request returns false without effects or semantic mutation.
///
/// ```zig
/// if (!try handler.execute(.{ .name = "agents" })) return;
/// ```
pub fn execute(handler: *RequestWorkspaceCreationHandler, command: RequestWorkspaceCreation) !bool {
    if (handler.gate.pending(handler.gate.context)) {
        return false;
    }

    try create_workspace.validateName(command.name);
    const cwd_source = handler.model.planWorkspaceCreation() orelse return false;
    try handler.effects.send(handler.effects.context, .{
        .name = command.name,
        .cwd_source = cwd_source,
    });

    return true;
}
