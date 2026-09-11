const Resources = @This();
const pane_mod = @import("../../../pane/root.zig");
const agent_mod = @import("../../../agent/root.zig");
const plugins = @import("../../../plugins/root.zig");
panes: *pane_mod.PaneStore,
agents: *agent_mod.Tracker,
service: *plugins.Service,
