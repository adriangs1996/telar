const PaneFocusResult = @This();
const source_namespace = @import("focus.zig");
request_id: source_namespace.RequestId,
outcome: source_namespace.PaneFocusOutcome,
focused_pane_id: source_namespace.PaneId,

/// Requires a focused pane identity only when the UI changed focus.
///
/// ```zig
/// try result.validateWire();
/// ```
pub fn validateWire(result: PaneFocusResult) !void {
    try source_namespace.validateRequestId(result.request_id);
    if (result.outcome == .focused) {
        try source_namespace.validatePaneId(result.focused_pane_id);
    }
}
