//! Planning a new workspace.

const model_namespace = @import("../state/model_namespace.zig");
const core = @import("telar-core");
const ClientModel = @import("../state/ClientModel.zig");

/// Returns the attached focused pane that may authorize a new workspace
/// launch, without changing client state.
///
/// ```zig
/// const pane_id = workspace_creation.plan(model) orelse return;
/// ```
pub fn plan(model: *const ClientModel) ?core.PaneId {
    return (model_namespace.focusedLaunchSource(model) orelse return null).pane_id;
}
