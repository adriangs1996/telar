const client = @import("telar-client");
const data = @import("model");
const core = @import("telar-core");
const LayoutRegions = @import("LayoutRegions.zig");
const tab_rename = @import("tab_rename.zig");
const StateType = @import("State.zig");
const MetricsType = @import("Metrics.zig");
const Input = @This();

regions: LayoutRegions,
tabs: ?*const data.TabsModel,
model: *const data.MultiplexerModel,
layout: *const data.LayoutSnapshot,
rename_field: ?*tab_rename.Field,
rename_kind: tab_rename.Kind,
prompt: ?*const data.Prompt = null,
path_completion: ?*const data.PathCompletionState = null,
sidebar_snapshot: *const data.AgentSnapshot,
sidebar_state: *StateType,
sidebar_transparent: bool,
sidebar_rounded_focus: bool,
sidebar_animation_frame: u8,
proxy_tls_active: bool,
proxy_tls_scope: core.ProxyScope = .exact,
proxy_system_trusted: bool = false,
system_metrics: ?MetricsType,
status_mode: client.Mode,
workspaces: *const data.WorkspaceListSnapshot,
workspace_list_collapsed: bool,
bar_state: *const data.BarsState,
