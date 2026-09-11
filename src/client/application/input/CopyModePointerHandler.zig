const CopyModePointerHandler = @This();
const Effects = @import("CopyModePointerEffects.zig");
const Command = @import("CopyModePointerCommand.zig");
const source_namespace = @import("copy_mode_pointer.zig");
effects: Effects,

/// Routes captured selection gestures before chrome or child input.
/// Keyboard copy mode consumes non-wheel events; its inside wheel moves
/// the copy cursor. Missing mouse geometry cancels on release.
///
/// ```zig
/// const outcome = try handler.execute(command, authority);
/// ```
pub fn execute(handler: *CopyModePointerHandler, command: Command, authority: source_namespace.Authority) !source_namespace.Outcome {
    const pointer_inside = switch (authority) {
        .unowned => return .unowned,
        .target_missing => {
            try handler.effects.leave(handler.effects.context);

            return .exited;
        },
        .selection => |selection| {
            if (selection.dragging and command.kind == .press and command.left_button) {
                try handler.effects.cancel_pointer(handler.effects.context);

                return .unowned;
            }

            if (!selection.dragging) {
                if (command.kind == .press or command.kind == .scroll_up or command.kind == .scroll_down) {
                    try handler.effects.cancel_pointer(handler.effects.context);
                }

                return .unowned;
            }

            if (!command.left_button or (command.kind != .drag and command.kind != .release)) {
                return .consumed;
            }

            const position = selection.position orelse {
                if (command.kind == .release) {
                    try handler.effects.cancel_pointer(handler.effects.context);
                }

                return .consumed;
            };
            try handler.effects.pointer(handler.effects.context, .{
                .position = position,
                .release = command.kind == .release,
            });
            return .moved;
        },
        .owned => |owned| owned.pointer_inside,
    };

    const delta: i32 = switch (command.kind) {
        .scroll_up => -3,
        .scroll_down => 3,
        else => return .consumed,
    };

    if (!pointer_inside) {
        return .consumed;
    }

    try handler.effects.vertical(handler.effects.context, delta);
    return .moved;
}
