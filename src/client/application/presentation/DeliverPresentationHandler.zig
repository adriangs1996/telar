const DeliverPresentationHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("Effects.zig");
const Command = @import("Command.zig");
const source_namespace = @import("presentation_delivery.zig");
model: *client_model.Model,
effects: Effects,

/// Commits one successful host presentation before delivering transport
/// effects in credits, frame and media order.
///
/// ```zig
/// try handler.execute(command);
/// ```
pub fn execute(handler: *DeliverPresentationHandler, command: Command) !void {
    if (command.commit.len > source_namespace.multiplexer.max_panes) {
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
