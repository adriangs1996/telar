const ModelType = @import("../../model/Model.zig");
const Effects = @import("PresentationEffects.zig");
const Command = @import("Command.zig");
const max_panes_per_tab = @import("telar-core").max_panes_per_tab;
const DeliverPresentationHandler = @This();

model: *ModelType,
effects: Effects,

/// Commits one successful host presentation before delivering transport
/// effects in credits, frame and media order.
///
/// ```zig
/// try handler.execute(command);
/// ```
pub fn execute(handler: *DeliverPresentationHandler, command: Command) !void {
    if (command.commit.len > max_panes_per_tab) {
        return error.InvalidPresentationCommit;
    }

    const accepted = handler.model.commitPresentation(command.commit);
    try handler.effects.flush_graphics_credits(handler.effects.context);

    for (accepted.slice()) |pane| {
        if (!pane.attached or pane.frame_id == 0) {
            continue;
        }

        try handler.effects.acknowledge_frame(handler.effects.context, .{ .pane_id = pane.pane_id, .frame_id = pane.frame_id });
    }

    if (command.media_pending) {
        try handler.effects.request_media(handler.effects.context);
    }
}
