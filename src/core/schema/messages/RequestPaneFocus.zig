const RequestPaneFocus = @This();
const source_namespace = @import("focus.zig");
request_id: source_namespace.RequestId,
pane_id: source_namespace.PaneId,
pane_generation: u64,
direction: source_namespace.PaneDirection,

/// Requires an exact live pane identity and a correlatable request.
///
/// ```zig
/// try request.validateWire();
/// ```
pub fn validateWire(request: RequestPaneFocus) !void {
    try source_namespace.validateRequestId(request.request_id);
    try source_namespace.validatePaneId(request.pane_id);
    if (request.pane_generation == 0) {
        return error.InvalidPaneGeneration;
    }
}
