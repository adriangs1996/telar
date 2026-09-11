const id = @import("../id.zig");
const types = @import("../types.zig");
const codec = @import("../codec.zig");
const PaneFocusResult = @This();

request_id: id.RequestId,
outcome: types.PaneFocusOutcome,
focused_pane_id: id.PaneId,

/// Requires a focused pane identity only when the UI changed focus.
///
/// ```zig
/// try result.validateWire();
/// ```
pub fn validateWire(result: PaneFocusResult) !void {
    try codec.validateRequestId(result.request_id);
    if (result.outcome == .focused) {
        try codec.validatePaneId(result.focused_pane_id);
    }
}
