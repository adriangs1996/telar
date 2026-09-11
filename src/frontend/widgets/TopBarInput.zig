const Input = @This();
const ui = @import("../ui/root.zig");
const source_namespace = @import("top_bar.zig");
const workspace_list = @import("telar-client").workspace.workspace_list;
const bars = @import("../bars/root.zig");
const status_bar = @import("status_bar.zig");
area: ui.Rect,
sidebar_visible: bool,
location: ?source_namespace.schema.TabLocation,
workspace_name: []const u8,
workspaces: *const workspace_list.Snapshot,
collapsed: bool,
proxy_tls_active: bool,
proxy_tls_scope: source_namespace.schema.ProxyScope = .exact,
proxy_system_trusted: bool = false,
right: *const bars.Slot = &source_namespace.empty_right,
system_metrics: ?status_bar.Metrics = null,
