const data = @import("model");
const core = @import("telar-core");
const client = @import("telar-client");
const top_bar = @import("top_bar.zig");
const Metrics = @import("Metrics.zig");
const Input = @This();

area: core.Rect,
sidebar_visible: bool,
location: ?core.TabLocation,
workspace_name: []const u8,
workspaces: *const data.WorkspaceListSnapshot,
collapsed: bool,
proxy_tls_active: bool,
proxy_tls_scope: core.ProxyScope = .exact,
proxy_system_trusted: bool = false,
right: *const data.bar_values.Slot = &top_bar.empty_right,
system_metrics: ?Metrics = null,
