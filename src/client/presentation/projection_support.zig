//! Immutable borrowed projections and owned presentation-completion values.

const data = @import("model");
const PresentationIngress = @import("PresentationIngress.zig");
const hints_support = @import("../input/hints_support.zig");
const Projection = @import("Projection.zig");
const CopyProjection = @import("../workspace/CopyProjection.zig");

/// Borrows model data only until the synchronous preparation call returns.
/// Refreshes the model's layout snapshot for the active tab first, so the
/// frame computes it at most once.
/// Example: `const projection = capture(&model, context);`.
pub fn capture(model: *data.ClientModel, context: Context) Projection {
    const tab = model.tabs.activeSlot();
    const layout: ?*const data.LayoutSnapshot = if (tab) |slot| data.tab_layout.snapshot(model, slot, context.geometry.area) else null;
    const copy: ?CopyProjection = if (data.copy_mode.currentProjection(model)) |value|
        .{ .pane_id = value.pane_id, .view = value.view }
    else
        null;
    const prompt = if (model.name_prompt.currentConst()) |value| value.* else null;

    return .{
        .version = model.version(),
        .geometry = context.geometry,
        .presentation_ingress = context.presentation_ingress,
        .model = model,
        .tab = tab,
        .layout = layout,
        .agents = &model.agent_snapshot,
        .sidebar_animation_frame = model.sidebar_animation_frame,
        .notifications = &model.notification_center,
        .workspaces = &model.workspace_list_snapshot,
        .prompt = prompt,
        .history = &model.history_palette,
        .suggestion = &model.suggestion,
        .path_completion = &model.path_completion,
        .proxy_tls_active = model.proxy_tls_active,
        .proxy_tls_scope = model.proxy_tls_scope,
        .proxy_system_trusted = model.proxy_system_trusted,
        .system_metrics = model.system_metrics,
        .bar_state = &model.bars,
        .status_mode = context.status_mode,
        .diagnostic = model.diagnostic(),
        .copy = copy,
        .sidebar_visible = model.sidebar_visible,
        .sidebar_width = model.sidebar_width,
        .workspace_list_collapsed = model.workspace_list_collapsed,
        .host_capabilities = model.host.host_capabilities,
        .host_size = model.host.host_size,
        .window_title_template = model.windowTitleTemplate(),
    };
}

const Context = struct {
    presentation_ingress: PresentationIngress = .{},
    status_mode: hints_support.Mode = .normal,
    geometry: data.Region,
};
