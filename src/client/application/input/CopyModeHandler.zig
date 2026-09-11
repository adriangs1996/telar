const CopyModeHandler = @This();
const client_model = @import("../../root.zig").model;
const CopyModeEffects = @import("CopyModeEffects.zig");
const input_capability = @import("../../input/root.zig");
const source_namespace = @import("copy_mode.zig");
model: *client_model.Model,
effects: CopyModeEffects,

/// Enters copy mode without performing runtime or presentation effects.
///
/// ```zig
/// if (handler.enter()) observe(handler.model.version());
/// ```
pub fn enter(handler: *CopyModeHandler) bool {
    return handler.model.enterCopyMode();
}

/// Starts a client-owned mouse gesture without entering keyboard copy mode.
/// Example: `_ = handler.beginPointer(press);`.
pub fn beginPointer(handler: *CopyModeHandler, press: input_capability.copy_mode.PointerPress) bool {
    return handler.model.beginPointerSelection(press);
}

/// Delivers a requested selection before closing local state, then
/// synchronizes a committed viewport. A failed copy keeps the mode open;
/// a failed viewport leaves the semantic commit intact.
///
/// ```zig
/// const outcome = try handler.execute(.{ .key = key });
/// ```
pub fn execute(handler: *CopyModeHandler, command: client_model.CopyModeCommand) !source_namespace.Outcome {
    defer {
        if (command == .cancel_pointer or (command == .pointer and command.pointer.release)) {
            handler.model.finishPointerGesture();
        }
    }

    const plan = handler.model.planCopyMode(command) orelse return .unchanged;
    if (plan.open_link) |target| {
        try handler.effects.open_link(handler.effects.context, target);

        return .unchanged;
    }
    if (plan.selection) |selection| {
        try handler.effects.copy(handler.effects.context, selection);
    }

    const commit = handler.model.commitCopyMode(plan) orelse return .unchanged;
    if (commit.viewport) |viewport| {
        try handler.effects.viewport.sync(handler.effects.viewport.context, viewport);
    }
    if (plan.search) |direction| {
        try handler.effects.open_search(handler.effects.context, direction);
    }

    return if (commit.active) .changed else .exited;
}
