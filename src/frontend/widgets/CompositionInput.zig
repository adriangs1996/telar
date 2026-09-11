const LayoutRegions = @import("LayoutRegions.zig");
const TabsModel = @import("telar-client").TabsModel;
const MultiplexerModel = @import("telar-client").MultiplexerModel;
const LayoutSnapshot = @import("telar-client").LayoutSnapshot;
const tab_rename = @import("tab_rename.zig");
const SnapshotType = @import("telar-client").AgentSnapshot;
const StateType = @import("State.zig");
const ProxyScopeType = @import("telar-core").ProxyScope;
const MetricsType = @import("Metrics.zig");
const ModeType = @import("telar-client").Mode;
const WorkspaceListSnapshot = @import("telar-client").WorkspaceListSnapshot;
const ClientState = @import("telar-client").State;
const Input = @This();

regions: LayoutRegions,
tabs: ?*const TabsModel,
model: *const MultiplexerModel,
layout: *const LayoutSnapshot,
rename_field: ?*tab_rename.Field,
rename_kind: tab_rename.Kind,
sidebar_snapshot: *const SnapshotType,
sidebar_state: *StateType,
sidebar_transparent: bool,
sidebar_rounded_focus: bool,
sidebar_animation_frame: u8,
proxy_tls_active: bool,
proxy_tls_scope: ProxyScopeType = .exact,
proxy_system_trusted: bool = false,
system_metrics: ?MetricsType,
status_mode: ModeType,
workspaces: *const WorkspaceListSnapshot,
workspace_list_collapsed: bool,
bar_state: *const ClientState,
