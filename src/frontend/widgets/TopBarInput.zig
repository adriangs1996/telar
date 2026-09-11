const RectType = @import("telar-core").Rect;
const TabLocationType = @import("telar-core").TabLocation;
const WorkspaceListSnapshot = @import("telar-client").WorkspaceListSnapshot;
const ProxyScopeType = @import("telar-core").ProxyScope;
const SlotType = @import("telar-client").Slot;
const top_bar = @import("top_bar.zig");
const MetricsType = @import("Metrics.zig");
const Input = @This();

area: RectType,
sidebar_visible: bool,
location: ?TabLocationType,
workspace_name: []const u8,
workspaces: *const WorkspaceListSnapshot,
collapsed: bool,
proxy_tls_active: bool,
proxy_tls_scope: ProxyScopeType = .exact,
proxy_system_trusted: bool = false,
right: *const SlotType = &top_bar.empty_right,
system_metrics: ?MetricsType = null,
