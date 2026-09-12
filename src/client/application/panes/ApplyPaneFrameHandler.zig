const ModelType = @import("../../model/Model.zig");
const PaneFrameEffects = @import("PaneFrameEffects.zig");
const FrameViewType = @import("telar-core").FrameView;
const types = @import("../../model/types.zig");
const ApplyPaneFrameHandler = @This();

model: *ModelType,
effects: PaneFrameEffects,

/// Acknowledges owned, validated cells before updating client resources. A
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
        .applied => |commit| {
            try handler.effects.acknowledge(handler.effects.context, .{ .pane_id = commit.pane_id, .frame_id = commit.frame_id });
            try handler.effects.deliver(handler.effects.context, commit);
        },
    }

    return outcome;
}
