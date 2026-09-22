const core = @import("telar-core");
const client = @import("telar-client");
const top_bar = @import("top_bar.zig");
const MetricsType = @import("Metrics.zig");
const Input = @This();

area: core.Rect,
sidebar_visible: bool,
location: ?core.TabLocation,
workspace_name: []const u8,
workspaces: *const client.WorkspaceListSnapshot,
collapsed: bool,
proxy_tls_active: bool,
proxy_tls_scope: core.ProxyScope = .exact,
proxy_system_trusted: bool = false,
right: *const client.Slot = &top_bar.empty_right,
system_metrics: ?MetricsType = null,
