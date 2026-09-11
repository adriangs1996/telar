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
pub fn validateWire(completion: CompletePaneFocus) !void {
    try completion.requester.validateWire();
    try codec.validateRequestId(completion.request_id);
    try codec.validatePaneId(completion.pane_id);
    if (completion.pane_generation == 0) {
        return error.InvalidPaneGeneration;
    }
    if (completion.outcome == .focused) {
        try codec.validatePaneId(completion.focused_pane_id);
    }
}
