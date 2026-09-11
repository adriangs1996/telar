const ModelType = @import("../../model/Model.zig");
const RenameWorkspaceOperationGate = @import("RenameWorkspaceOperationGate.zig");
const RenameRequestEffects = @import("RenameRequestEffects.zig");
const RequestRenameWorkspace = @import("RequestRenameWorkspace.zig");
const std = @import("std");
const RequestRenameWorkspaceHandler = @This();

model: *const ModelType,
gate: RenameWorkspaceOperationGate,
effects: RenameRequestEffects,

/// Validates the prompt target and sends one rename intent. Pending
/// operations and stale workspace targets return false without effects.
///
/// ```zig
/// if (!try handler.execute(command)) return;
/// ```
pub fn execute(handler: *RequestRenameWorkspaceHandler, command: RequestRenameWorkspace) !bool {
    if (handler.gate.pending(handler.gate.context)) {
        return false;
    }

    const current = handler.model.workspaceLocation() orelse return false;
    if (!std.meta.eql(current, command.workspace)) {
        return false;
    }

    try handler.effects.send(handler.effects.context, .{
        .workspace = command.workspace,
        .name = command.name,
    });

    return true;
}
