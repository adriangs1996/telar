const RetireReportedPaneFocusHandler = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("pane_focus_reporting.zig");
model: *client_model.Model,

/// Forgets focus reporting after a canonical transition invalidates its
/// owner. This use case has no delivery port and cannot emit focus-out.
///
/// ```zig
/// _ = handler.execute();
/// ```
pub fn execute(handler: *RetireReportedPaneFocusHandler) source_namespace.Outcome {
    return if (handler.model.forgetReportedPaneFocus()) .applied else .unchanged;
}
