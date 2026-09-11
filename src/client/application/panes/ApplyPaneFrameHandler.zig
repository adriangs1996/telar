const ApplyPaneFrameHandler = @This();
const client_model = @import("../../root.zig").model;
const PaneFrameEffects = @import("PaneFrameEffects.zig");
const source_namespace = @import("pane_frame.zig");
model: *client_model.Model,
effects: PaneFrameEffects,

/// Commits a valid attached frame before updating client resources. A
/// broken patch base requests a snapshot without mutation, while a frame
/// made stale by detach has no effects.
///
/// ```zig
/// const outcome = try handler.execute(frame);
/// ```
pub fn execute(handler: *ApplyPaneFrameHandler, frame: source_namespace.schema.frame.FrameView) !client_model.PaneFrameOutcome {
    const outcome = try handler.model.applyPaneFrame(frame);
    switch (outcome) {
        .detached => {},
        .resync => |recovery| try handler.effects.recover(handler.effects.context, recovery),
        .applied => |commit| try handler.effects.deliver(handler.effects.context, commit),
    }

    return outcome;
}
