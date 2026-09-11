const ReconcilePaneGraphicsHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("PaneGraphicsEffects.zig");
const source_namespace = @import("pane_graphics.zig");
model: *client_model.Model,
effects: Effects,

/// Reconciles one physical resource result, then commits its derived cell
/// fallback or performs bounded recovery. Presentation observes versions.
///
/// ```zig
/// const outcome = try handler.execute(command);
/// ```
pub fn execute(handler: *ReconcilePaneGraphicsHandler, command: source_namespace.Command) !source_namespace.Outcome {
    const pane_id = command.paneId();
    const resource = try handler.effects.apply(handler.effects.context, command);

    return switch (resource) {
        .unchanged => .unchanged,
        .changed => |state| block: {
            if (state.pane_id != pane_id) {
                return error.InvalidPaneGraphicsResult;
            }

            break :block .{ .applied = .{
                .pane_id = pane_id,
                .fallback = handler.model.setPaneGraphicsFallback(
                    pane_id,
                    handler.model.hostCapabilities().images != .supported and
                        state.has_graphics,
                ),
            } };
        },
        .resync_required => |recovery_pane| block: {
            if (recovery_pane != pane_id) {
                return error.InvalidPaneGraphicsResult;
            }

            try handler.effects.request_snapshot(handler.effects.context, pane_id);
            break :block .{ .resync_requested = pane_id };
        },
        .shared_mapping_failed => |recovery_pane| block: {
            if (recovery_pane != pane_id) {
                return error.InvalidPaneGraphicsResult;
            }

            try handler.effects.disable_shared(handler.effects.context);
            try handler.effects.request_snapshot(handler.effects.context, pane_id);
            break :block .{ .shared_disabled = pane_id };
        },
    };
}
