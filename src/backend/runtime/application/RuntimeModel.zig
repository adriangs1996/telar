const RuntimeModel = @This();
const workspace = @import("../../workspace/root.zig");
const pane = @import("../../pane/root.zig");
const agent = @import("../../agent/root.zig");
const client_layout_store = @import("client_layout_store.zig");
workspaces: workspace.State = .{},
panes: pane.PaneStore,
agents: agent.Tracker = .{},
client_layouts: client_layout_store.Store = .{},
