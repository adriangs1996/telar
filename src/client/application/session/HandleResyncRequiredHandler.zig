const ResyncRequiredEffects = @import("ResyncRequiredEffects.zig");
const resync_required = @import("resync_required.zig");
const Reconciliation = @import("Reconciliation.zig");
const std = @import("std");
const WorkspaceClosure = @import("WorkspaceClosure.zig");
const HandleResyncRequiredHandler = @This();

effects: ResyncRequiredEffects,

/// Reconciles the current workspace or follows the runtime after closure.
/// A closed workspace loses its bookmark before handoff or exit.
///
/// ```zig
/// const outcome = try handler.execute(command);
/// ```
pub fn execute(handler: *HandleResyncRequiredHandler, command: resync_required.Command) !resync_required.Outcome {
    return switch (command) {
        .reconcile => |state| handler.reconcile(state),
        .workspace_closed => |closure| handler.closeWorkspace(closure),
    };
}

fn reconcile(handler: *HandleResyncRequiredHandler, command: Reconciliation) !resync_required.Outcome {
    const projected = command.projected_workspace orelse return error.UnexpectedResync;
    if (!std.meta.eql(projected, command.required_workspace)) {
        return error.UnexpectedResync;
    }

    if (command.snapshot_pending) {
        return .coalesced;
    }

    try handler.effects.request_snapshot(handler.effects.context, command.required_workspace);
    return .snapshot_requested;
}

fn closeWorkspace(handler: *HandleResyncRequiredHandler, command: WorkspaceClosure) !resync_required.Outcome {
    handler.effects.forget_workspace(handler.effects.context, command.workspace);

    const previous = command.previous_workspace orelse return .exit;
    try handler.effects.request_handoff(handler.effects.context, previous);

    return .handoff_requested;
}
