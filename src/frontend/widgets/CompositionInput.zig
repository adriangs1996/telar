const Input = @This();
const layout_module = @import("layout.zig");
const source_namespace = @import("composition.zig");
const tab_rename = @import("tab_rename.zig");
const agents = @import("telar-client").agents;
const sidebar = @import("sidebar.zig");
const status_bar = @import("status_bar.zig");
const bars = @import("../bars/root.zig");
regions: layout_module.Regions,
tabs: ?*const source_namespace.tabs_mod.Model,
model: *const source_namespace.multiplexer.Model,
layout: *const source_namespace.layout_mod.Snapshot,
rename_field: ?*tab_rename.Field,
rename_kind: tab_rename.Kind,
sidebar_snapshot: *const agents.Snapshot,
sidebar_state: *sidebar.State,
sidebar_transparent: bool,
sidebar_rounded_focus: bool,
sidebar_animation_frame: u8,
proxy_tls_active: bool,
proxy_tls_scope: source_namespace.schema.ProxyScope = .exact,
proxy_system_trusted: bool = false,
system_metrics: ?status_bar.Metrics,
status_mode: status_bar.Mode,
workspaces: *const source_namespace.workspace_list.Snapshot,
workspace_list_collapsed: bool,
bar_state: *const bars.State,
