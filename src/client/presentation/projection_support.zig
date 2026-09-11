//! Immutable borrowed projections and owned presentation-completion values.
const core = @import("telar-core");
pub const schema = core.schema;
const client_model = @import("../model/root.zig");
const multiplexer = @import("../workspace/root.zig").multiplexer;
const tabs = @import("../workspace/root.zig").tabs;
const workspace_list = @import("../workspace/root.zig").workspace_list;
const agents = @import("../agents/root.zig");
const notifications = @import("../notifications/root.zig");
pub const name_prompt = client_model.name_prompt;
pub const history_palette_state = client_model.history_palette;
pub const suggestion_state = client_model.suggestion;
const bars = @import("../bars/root.zig");
const input = @import("../input/root.zig");

pub const Observation = @import("Observation.zig");

pub const PresentationIngress = @import("PresentationIngress.zig");

pub const Projection = @import("Projection.zig");

pub const Delivery = @import("Delivery.zig");

pub const Context = @import("Context.zig");

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
