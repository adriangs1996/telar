//! Client application use cases.

pub const close_tab = @import("close_tab.zig");
pub const create_tab = @import("create_tab.zig");
pub const rename_tab = @import("rename_tab.zig");
pub const rename_workspace = @import("rename_workspace.zig");
pub const select_tab = @import("select_tab.zig");
pub const workspace_snapshot = @import("workspace_snapshot.zig");

test {
    _ = close_tab;
    _ = create_tab;
    _ = rename_tab;
    _ = rename_workspace;
    _ = select_tab;
    _ = workspace_snapshot;
}
