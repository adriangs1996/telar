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
pub fn validateWire(request: RequestPaneFocus) !void {
    try codec.validateRequestId(request.request_id);
    try codec.validatePaneId(request.pane_id);
    if (request.pane_generation == 0) {
        return error.InvalidPaneGeneration;
    }
}
