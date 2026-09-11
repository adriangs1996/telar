const FrameAckHandler = @This();
const source_namespace = @import("frame_ack.zig");
const AcknowledgeFrame = @import("AcknowledgeFrame.zig");
attachments: *source_namespace.AttachmentStore,

/// Releases the exact outstanding frame for one client attachment and
/// returns its delivery latency. Missing, older, future, and duplicate
/// acknowledgements are stale and leave synchronization state unchanged.
///
/// ```zig
/// const result = try handler.execute(acknowledgement);
/// ```
pub fn execute(handler: *FrameAckHandler, command: AcknowledgeFrame) !source_namespace.FrameAckResult {
    const elapsed = handler.attachments.acknowledgeFrame(.{
        .pane_id = command.pane_id,
        .frame_id = command.frame_id,
    }, command.received_at_ns) orelse return .stale;

    return .{ .acknowledged = elapsed };
}
