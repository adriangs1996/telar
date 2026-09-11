const ModelType = @import("../../model/Model.zig");
const PaneFrameEffects = @import("PaneFrameEffects.zig");
const FrameViewType = @import("telar-core").FrameView;
const types = @import("../../model/types.zig");
const ApplyPaneFrameHandler = @This();

model: *ModelType,
effects: PaneFrameEffects,

/// Commits a valid attached frame before updating client resources. A
/// broken patch base requests a snapshot without mutation, while a frame
/// made stale by detach has no effects.
///
/// ```zig
/// const outcome = try handler.execute(frame);
/// ```
pub fn execute(handler: *ApplyPaneFrameHandler, frame: FrameViewType) !types.PaneFrameOutcome {
    const outcome = try handler.model.applyPaneFrame(frame);
    switch (outcome) {
        .detached => {},
        .resync => |recovery| try handler.effects.recover(handler.effects.context, recovery),
        .applied => |commit| try handler.effects.deliver(handler.effects.context, commit),
    }

    return outcome;
}
