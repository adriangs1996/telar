//! Bounded replica of the runtime's open-workspace list.
//!
//! The runtime owns workspace truth. One disposable client model keeps this
//! fixed-capacity value for navigation and presentation. Newer revisions
//! replace it atomically; stale or oversized snapshots preserve the last
//! usable value.

const WorkspaceListCollapse = @import("../state/WorkspaceListCollapse.zig");
const ClientModel = @import("../state/ClientModel.zig");
const core = @import("telar-core");

/// Names arrive whole; views clip them to the room they have.
pub const max_name_bytes = core.max_workspace_name_bytes;
/// Bytes of path the pool holds for each workspace on average; paths of a
/// project or worktree checkout run well under it.
const average_path_bytes = 512;
/// One shared pool for every stored path. Paths stay whole so the replica
/// never exposes a fabricated location: a list whose paths do not all fit
/// keeps the entries before the first that does not and counts the rest in
/// `dropped`.
pub const path_pool_size = core.max_workspace_list_entries * average_path_bytes;
pub const path_pool_limit = core.Limit.declare("workspace_list.path_pool_size", "path bytes", path_pool_size);

/// Commits an explicit workspace-list collapse preference. Repeated
/// values preserve the chrome revision.
///
/// ```zig
/// const change = workspace_list.setCollapsed(model, true) orelse return;
/// ```
pub fn setCollapsed(model: *ClientModel, collapsed: bool) ?WorkspaceListCollapse {
    if (model.workspace_list_collapsed == collapsed) {
        return null;
    }

    model.workspace_list_collapsed = collapsed;
    model.chrome_revision +%= 1;

    return .{
        .chrome_revision = model.chrome_revision,
    };
}

/// Toggles the workspace-list preference and advances only chrome.
///
/// ```zig
/// const change = workspace_list.toggle(model);
/// ```
pub fn toggle(model: *ClientModel) WorkspaceListCollapse {
    return setCollapsed(model, !model.workspace_list_collapsed).?;
}
