//! Immutable semantic projection and explicit presentation-owned resources for
//! one synchronous client frame.

const presenter = @import("presenter.zig");
const multiplexer = @import("../../workspace/root.zig").multiplexer;

const Client = @import("../client.zig");

/// Captures the bounded revisions observed by the presenter after one client
/// event without exposing the client aggregate.
///
/// ```zig
/// try client.presenter.observe(observation(client));
/// ```
pub fn observation(client: *Client) presenter.Observation {
    return .{
        .model = client.model.version(),
        .graphics_ingress = client.graphics_store.ingressVersion(),
        .attachment_ingress = client.view.kittyAttachments().ingressVersion(),
        .presentation_ingress = presentationIngress(client),
    };
}

/// Borrows one immutable semantic projection for a synchronous cell or media
/// presentation. The event loop cannot mutate it until the call returns.
///
/// ```zig
/// const current = projection(client);
/// ```
pub fn projection(client: *const Client) presenter.Projection {
    const copy: ?multiplexer.CopyProjection = if (client.model.copyModeProjection()) |value|
        .{ .pane_id = value.pane_id, .view = value.view }
    else
        null;
    const prompt = if (client.model.name_prompt.currentConst()) |value| value.* else null;

    return .{
        .version = client.model.version(),
        .presentation_ingress = presentationIngress(client),
        .model = client.model.activeTabModelConst(),
        .tabs = &client.model.workspace,
        .agents = client.model.agentSnapshot(),
        .sidebar_animation_frame = client.model.sidebarAnimationFrame(),
        .notifications = client.model.notificationSnapshot(),
        .workspaces = client.model.workspaceListSnapshot(),
        .prompt = prompt,
        .proxy_tls_active = client.model.proxyTlsActive(),
        .system_metrics = client.model.systemMetrics(),
        .bar_state = client.model.barState(),
        .status_mode = client.host_input.statusMode(client.model.copyModeActive()),
        .diagnostic = client.model.diagnostic(),
        .copy = copy,
        .sidebar_visible = client.model.sidebarVisible(),
        .sidebar_width = client.model.sidebarWidth(),
        .workspace_list_collapsed = client.model.workspaceListCollapsed(),
        .host_capabilities = client.model.hostCapabilities(),
        .host_size = client.model.hostSize(),
        .window_title_template = client.model.windowTitleTemplate(),
    };
}

fn presentationIngress(client: *const Client) presenter.PresentationIngress {
    return .{
        .view_interaction = client.view.interactionVersion(),
        .input_routing = client.host_input.presentationVersion(),
    };
}

/// Exposes only the mutable resources that presentation owns and the host
/// writer that receives its output.
///
/// ```zig
/// const target = resources(client);
/// ```
pub fn resources(client: *Client) presenter.Resources {
    return .{
        .view = &client.view,
        .graphics_store = &client.graphics_store,
        .writer = client.writer,
    };
}
