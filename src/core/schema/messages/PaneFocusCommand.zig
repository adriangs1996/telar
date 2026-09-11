const PaneFocusCommand = @This();
const ClientRoute = @import("ClientRoute.zig");
const source_namespace = @import("focus.zig");
requester: ClientRoute,
request_id: source_namespace.RequestId,
pane_id: source_namespace.PaneId,
pane_generation: u64,
direction: source_namespace.PaneDirection,

/// Requires the runtime route and exact pane generation sent to the UI.
///
/// ```zig
/// try command.validateWire();
/// ```
pub fn validateWire(command: PaneFocusCommand) !void {
    try command.requester.validateWire();
    try source_namespace.validateRequestId(command.request_id);
    try source_namespace.validatePaneId(command.pane_id);
    if (command.pane_generation == 0) {
        return error.InvalidPaneGeneration;
    }
}
