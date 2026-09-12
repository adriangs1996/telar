//! Confirms that validated cells are owned by the client model. Presentation
//! completion and graphics-resource credits have independent lifetimes.
const id = @import("../id.zig");
const FrameAck = @This();

pane_id: id.PaneId,
frame_id: u64,

pub fn validateWire(message: FrameAck) !void {
    if (message.frame_id == 0) {
        return error.InvalidFrameId;
    }
}
