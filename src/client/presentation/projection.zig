const Projection = @This();
const client_model = @import("../model/root.zig");
const PresentationIngress = @import("PresentationIngress.zig");
const multiplexer = @import("../workspace/root.zig").multiplexer;
const tabs_module = @import("../workspace/root.zig").tabs;
const agents_module = @import("../agents/root.zig");
const notifications_module = @import("../notifications/root.zig");
const workspace_list = @import("../workspace/root.zig").workspace_list;
const source_namespace = @import("projection_support.zig");
const bars = @import("../bars/root.zig");
const input = @import("../input/root.zig");
version: client_model.Version,
geometry: @import("../workspace/root.zig").geometry.Region,
presentation_ingress: PresentationIngress = .{},
model: ?*const multiplexer.Model,
tabs: *const tabs_module.Model,
agents: *const agents_module.Snapshot,
sidebar_animation_frame: u8,
notifications: *const notifications_module.Center,
workspaces: *const workspace_list.Snapshot,
prompt: ?source_namespace.name_prompt.Prompt,
history: *const source_namespace.history_palette_state.State,
suggestion: *const source_namespace.suggestion_state.State,
proxy_tls_active: bool,
proxy_tls_scope: source_namespace.schema.ProxyScope,
proxy_system_trusted: bool,
system_metrics: ?client_model.SystemMetrics,
bar_state: *const bars.State,
status_mode: input.hints.Mode,
diagnostic: ?[]const u8,
copy: ?multiplexer.CopyProjection,
sidebar_visible: bool,
sidebar_width: u16,
workspace_list_collapsed: bool,
host_capabilities: client_model.HostCapabilities,
host_size: source_namespace.schema.TerminalSize,
/// Configured host window title template; empty leaves the host alone.
window_title_template: []const u8 = "",
