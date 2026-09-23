const ClientRoute = @import("ClientRoute.zig");
const id = @import("../id.zig");
const types = @import("../types.zig");
const codec = @import("../codec.zig");
const PaneFocusCommand = @This();

requester: ClientRoute,
request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
direction: types.PaneDirection,

/// Requires the runtime route and exact pane generation sent to the UI.
///
/// ```zig
/// try command.validateWire();
/// ```
pub fn validateWire(self: PaneFocusCommand) !void {
    try self.requester.validateWire();
    try codec.validateRequestId(self.request_id);
    try codec.validatePaneId(self.pane_id);
    if (self.pane_generation == 0) {
        return error.InvalidPaneGeneration;
    }
}
