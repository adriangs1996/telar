const FrameAck = @This();
const source_namespace = @import("pane.zig");
pane_id: source_namespace.PaneId,
frame_id: u64,

pub fn validateWire(message: FrameAck) !void {
    if (message.frame_id == 0) {
        return error.InvalidFrameId;
    }
}
