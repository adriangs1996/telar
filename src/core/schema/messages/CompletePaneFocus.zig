const ClientRoute = @import("ClientRoute.zig");
const id = @import("../id.zig");
const types = @import("../types.zig");
const codec = @import("../codec.zig");
const CompletePaneFocus = @This();

requester: ClientRoute,
request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
outcome: types.PaneFocusOutcome,
focused_pane_id: id.PaneId,

/// Validates the echoed route and the focused pane required on success.
///
/// ```zig
/// try completion.validateWire();
/// ```
pub fn validateWire(self: CompletePaneFocus) !void {
    try self.requester.validateWire();
    try codec.validateRequestId(self.request_id);
    try codec.validatePaneId(self.pane_id);
    if (self.pane_generation == 0) {
        return error.InvalidPaneGeneration;
    }
    if (self.outcome == .focused) {
        try codec.validatePaneId(self.focused_pane_id);
    }
}
