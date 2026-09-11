const AdmitWorkspaceHandoffHandler = @This();
const client_model = @import("../../root.zig").model;
const Gate = @import("Gate.zig");
const source_namespace = @import("workspace_handoff_admission.zig");
model: *const client_model.Model,
gate: Gate,

/// Admits a requested departure only while idle, or a canonical follow
/// only after the current projection has already disappeared.
///
/// ```zig
/// try handler.execute(.requested_departure);
/// ```
pub fn execute(handler: *const AdmitWorkspaceHandoffHandler, authority: source_namespace.Authority) !void {
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
