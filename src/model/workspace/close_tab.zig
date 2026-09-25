//! Application use cases for requesting closure and applying tab removal.

const ApplyTabRemoval = @import("ApplyTabRemoval.zig");

pub const RemovalTrigger = @import("TabCloseRemovalTrigger.zig").TabCloseRemovalTrigger;

pub fn validateWorkspaceTransition(command: ApplyTabRemoval) !void {
    if (!command.workspace_removed and command.previous_workspace != null) {
        return error.UnexpectedPreviousWorkspace;
    }

    const previous = command.previous_workspace orelse return;
    const removed = switch (command.location.workspace) {
        .workspace => |workspace| workspace,
        .worktree => return error.InvalidWorkspaceSuccessor,
    };

    if (previous == removed) {
        return error.InvalidWorkspaceSuccessor;
    }
}
