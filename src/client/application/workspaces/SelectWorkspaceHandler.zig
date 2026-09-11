const SelectWorkspaceHandler = @This();
const client_model = @import("../../root.zig").model;
const SelectionGate = @import("SelectionGate.zig");
const SelectionEffects = @import("SelectionEffects.zig");
const source_namespace = @import("workspace_handoff.zig");
model: *const client_model.Model,
gate: SelectionGate,
effects: SelectionEffects,

/// Resolves one listed workspace target and requests a handoff only when
/// it is known, different from the active workspace and not blocked.
///
/// ```zig
/// if (!try handler.execute(.{ .position = 1 })) return;
/// ```
pub fn execute(handler: *SelectWorkspaceHandler, target: source_namespace.SelectionTarget) !bool {
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
