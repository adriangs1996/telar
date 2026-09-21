//! Application use cases for requesting closure and applying tab removal.

const ApplyTabRemoval = @import("ApplyTabRemoval.zig");

pub const RemovalTrigger = enum {
    requested,
    lifecycle,
};

pub const TabRemovalDirective = enum {
    continue_running,
    exit,
};

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

pub const RequestStep = enum {
    prepare,
    detach,
    send,
    restore,
};
