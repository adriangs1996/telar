//! Immutable borrowed projections and owned presentation-completion values.
const core = @import("telar-core");
const schema = core.schema;
const client_model = @import("../model/root.zig");
const multiplexer = @import("../workspace/root.zig").multiplexer;
const tabs = @import("../workspace/root.zig").tabs;
const workspace_list = @import("../workspace/root.zig").workspace_list;
const agents = @import("../agents/root.zig");
const notifications = @import("../notifications/root.zig");
const name_prompt = client_model.name_prompt;
const history_palette_state = client_model.history_palette;
const suggestion_state = client_model.suggestion;
const bars = @import("../bars/root.zig");
const input = @import("../input/root.zig");

pub const Observation = struct {
    model: client_model.Version = .{},
    graphics_ingress: u64 = 0,
    attachment_ingress: u64 = 0,
    geometry_revision: u64 = 0,
    presentation_ingress: PresentationIngress = .{},
};

pub const PresentationIngress = struct {
    view_interaction: u64 = 0,
    input_routing: u64 = 0,
};

pub const Projection = struct {
    version: client_model.Version,
    geometry: @import("../workspace/root.zig").geometry.Region,
    presentation_ingress: PresentationIngress = .{},
    model: ?*const multiplexer.Model,
    tabs: *const tabs.Model,
    agents: *const agents.Snapshot,
    sidebar_animation_frame: u8,
    notifications: *const notifications.Center,
    workspaces: *const workspace_list.Snapshot,
    prompt: ?name_prompt.Prompt,
    history: *const history_palette_state.State,
    suggestion: *const suggestion_state.State,
    proxy_tls_active: bool,
    proxy_tls_scope: schema.ProxyScope,
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
    host_size: schema.TerminalSize,
    /// Configured host window title template; empty leaves the host alone.
    window_title_template: []const u8 = "",
};

pub const Delivery = struct {
    commit: multiplexer.PresentationCommit,
    media_pending: bool,
};

pub const Context = struct {
    presentation_ingress: PresentationIngress = .{},
    status_mode: input.hints.Mode = .normal,
    geometry: @import("../workspace/root.zig").geometry.Region,
};

/// Borrows model data only until the synchronous preparation call returns.
/// Example: `const projection = capture(&model, context);`.
pub fn capture(model: *const client_model.Model, context: Context) Projection {
    const copy: ?multiplexer.CopyProjection = if (model.copyModeProjection()) |value|
        .{ .pane_id = value.pane_id, .view = value.view }
    else
        null;
    const prompt = if (model.name_prompt.currentConst()) |value| value.* else null;

    return .{
        .version = model.version(),
        .geometry = context.geometry,
        .presentation_ingress = context.presentation_ingress,
        .model = model.activeTabModelConst(),
        .tabs = &model.workspace,
        .agents = model.agentSnapshot(),
        .sidebar_animation_frame = model.sidebarAnimationFrame(),
        .notifications = model.notificationSnapshot(),
        .workspaces = model.workspaceListSnapshot(),
        .prompt = prompt,
        .history = &model.history_palette,
        .suggestion = &model.suggestion,
        .proxy_tls_active = model.proxyTlsActive(),
        .proxy_tls_scope = model.proxyTlsScope(),
        .proxy_system_trusted = model.proxySystemTrusted(),
        .system_metrics = model.systemMetrics(),
        .bar_state = model.barState(),
        .status_mode = context.status_mode,
        .diagnostic = model.diagnostic(),
        .copy = copy,
        .sidebar_visible = model.sidebarVisible(),
        .sidebar_width = model.sidebarWidth(),
        .workspace_list_collapsed = model.workspaceListCollapsed(),
        .host_capabilities = model.hostCapabilities(),
        .host_size = model.hostSize(),
        .window_title_template = model.windowTitleTemplate(),
    };
}
