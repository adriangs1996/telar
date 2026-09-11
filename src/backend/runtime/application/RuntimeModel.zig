const StateType = @import("../../workspace/State.zig");
const PaneStoreType = @import("../../pane/PaneStore.zig");
const TrackerType = @import("../../agent/Tracker.zig");
const StoreType = @import("Store.zig");
const RuntimeModel = @This();

workspaces: StateType = .{},
panes: PaneStoreType,
agents: TrackerType = .{},
client_layouts: StoreType = .{},
