const CompletePaneFocus = @This();
const ClientRoute = @import("ClientRoute.zig");
const source_namespace = @import("focus.zig");
requester: ClientRoute,
request_id: source_namespace.RequestId,
pane_id: source_namespace.PaneId,
pane_generation: u64,
outcome: source_namespace.PaneFocusOutcome,
focused_pane_id: source_namespace.PaneId,

/// Validates the echoed route and the focused pane required on success.
///
/// ```zig
/// try completion.validateWire();
/// ```
pub fn validateWire(completion: CompletePaneFocus) !void {
    try completion.requester.validateWire();
    try source_namespace.validateRequestId(completion.request_id);
    try source_namespace.validatePaneId(completion.pane_id);
    if (completion.pane_generation == 0) {
        return error.InvalidPaneGeneration;
    }
    if (completion.outcome == .focused) {
        try source_namespace.validatePaneId(completion.focused_pane_id);
    }
}
