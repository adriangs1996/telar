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
pub fn validateWire(command: PaneFocusCommand) !void {
    try command.requester.validateWire();
    try codec.validateRequestId(command.request_id);
    try codec.validatePaneId(command.pane_id);
    if (command.pane_generation == 0) {
        return error.InvalidPaneGeneration;
    }
}
