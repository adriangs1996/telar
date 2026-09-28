const core = @import("telar-core");
const data = @import("model");
/// What `order` reads.
const FleetSources = @This();

agents: []const data.Agent,
workspaces: *const data.WorkspaceListSnapshot,
/// The pane focused in the active tab, whose task is drawn in full.
focused: ?core.PaneId = null,
