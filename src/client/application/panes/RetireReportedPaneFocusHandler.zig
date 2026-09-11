const ModelType = @import("../../model/Model.zig");
const pane_focus_reporting = @import("pane_focus_reporting.zig");
const RetireReportedPaneFocusHandler = @This();

model: *ModelType,

/// Forgets focus reporting after a canonical transition invalidates its
/// owner. This use case has no delivery port and cannot emit focus-out.
///
/// ```zig
/// _ = handler.execute();
/// ```
pub fn execute(handler: *RetireReportedPaneFocusHandler) pane_focus_reporting.Outcome {
    return if (handler.model.forgetReportedPaneFocus()) .applied else .unchanged;
}
