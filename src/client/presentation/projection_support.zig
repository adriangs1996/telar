//! Immutable borrowed projections and owned presentation-completion values.

const ModelType = @import("../model/Model.zig");
const Context = @import("Context.zig");
const Projection = @import("Projection.zig");
const CopyProjectionType = @import("../workspace/CopyProjection.zig");

/// Borrows model data only until the synchronous preparation call returns.
/// Example: `const projection = capture(&model, context);`.
pub fn capture(model: *const ModelType, context: Context) Projection {
    const copy: ?CopyProjectionType = if (model.copyModeProjection()) |value|
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
