const Sources = @This();
const source_namespace = @import("client_layout_store.zig");
const workspace_mod = @import("../../workspace/root.zig");
panes: *const source_namespace.PaneStore,
workspaces: workspace_mod.Reader,
