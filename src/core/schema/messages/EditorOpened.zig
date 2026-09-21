const id = @import("../id.zig");
const codec = @import("../codec.zig");
const EditorOpened = @This();

pub const Outcome = enum(u8) { unavailable, opened, failed };

request_id: id.RequestId,
outcome: Outcome,
pane_id: id.PaneId = .invalid,
pane_generation: u64 = 0,

/// A successful open identifies the exact editor pane. Example: `try reply.validateWire();`
pub fn validateWire(self: EditorOpened) !void {
    try codec.validateRequestId(self.request_id);
    if (self.outcome == .opened) {
        try codec.validatePaneId(self.pane_id);
        if (self.pane_generation == 0) {
            return error.InvalidPaneGeneration;
        }
    }
}
