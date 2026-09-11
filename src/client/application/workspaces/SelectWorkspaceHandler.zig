const ModelType = @import("../../model/Model.zig");
const SelectionGate = @import("SelectionGate.zig");
const SelectionEffects = @import("SelectionEffects.zig");
const workspace_handoff = @import("workspace_handoff.zig");
const SelectWorkspaceHandler = @This();

model: *const ModelType,
gate: SelectionGate,
effects: SelectionEffects,

/// Resolves one listed workspace target and requests a handoff only when
/// it is known, different from the active workspace and not blocked.
///
/// ```zig
/// if (!try handler.execute(.{ .position = 1 })) return;
/// ```
pub fn execute(handler: *SelectWorkspaceHandler, target: workspace_handoff.SelectionTarget) !bool {
    if (handler.gate.pending(handler.gate.context)) {
        return false;
    }

    const workspace = switch (target) {
        .position => |position| handler.model.workspaceAtPosition(position) orelse return false,
        .workspace => |workspace| workspace,
    };
    if (!handler.model.knowsWorkspace(workspace)) {
        return false;
    }
    if (handler.model.workspaceLocation()) |current| {
        switch (current) {
            .workspace => |active| {
                if (active == workspace) {
                    return false;
                }
            },
            .worktree => {},
        }
    }

    try handler.effects.request(handler.effects.context, workspace);

    return true;
}
