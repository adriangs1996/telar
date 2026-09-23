const PaneStoreType = @import("../../pane/PaneStore.zig");
const Workspaces = @import("../../workspace/Workspaces.zig");
const Sources = @This();

panes: *const PaneStoreType,
workspaces: *const Workspaces,
