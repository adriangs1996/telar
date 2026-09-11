const ModelType = @import("../../model/Model.zig");
const Gate = @import("Gate.zig");
const workspace_handoff_admission = @import("workspace_handoff_admission.zig");
const AdmitWorkspaceHandoffHandler = @This();

model: *const ModelType,
gate: Gate,

/// Admits a requested departure only while idle, or a canonical follow
/// only after the current projection has already disappeared.
///
/// ```zig
/// try handler.execute(.requested_departure);
/// ```
pub fn execute(handler: *const AdmitWorkspaceHandoffHandler, authority: workspace_handoff_admission.Authority) !void {
    switch (authority) {
        .requested_departure => {
            if (handler.gate.pending(handler.gate.context)) {
                return error.WorkspaceSwitchWhileRequestPending;
            }
        },
        .canonical_follow => {
            if (handler.model.workspaceLocation() != null) {
                return error.WorkspaceStillActive;
            }
        },
    }
}
