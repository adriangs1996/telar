const id = @import("../id.zig");
const types = @import("../types.zig");
const codec = @import("../codec.zig");
const RequestPaneFocus = @This();

request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
direction: types.PaneDirection,

/// Requires an exact live pane identity and a correlatable request.
///
/// ```zig
/// try request.validateWire();
/// ```
pub fn validateWire(self: RequestPaneFocus) !void {
    try codec.validateRequestId(self.request_id);
    try codec.validatePaneId(self.pane_id);
    if (self.pane_generation == 0) {
        return error.InvalidPaneGeneration;
    }
}
