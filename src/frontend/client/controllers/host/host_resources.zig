//! Adapts committed host-resource commands to one concrete client.

const core = @import("telar-core");
const host_application = @import("../../application/host/root.zig");
const client_model = @import("../../model/root.zig");
const pane_geometry = @import("../panes/pane_geometry.zig");
const pane_graphics = @import("../panes/pane_graphics.zig");

const Client = @import("../../client.zig");
const host_resource_delivery = host_application.host_resource_delivery;
const schema = core.schema;

/// Delivers every disposable resource implied by one current host commit.
///
/// ```zig
/// try deliver(client, commit);
/// ```
pub fn deliver(client: *Client, commit: client_model.HostCommit) !void {
    var use_case: host_resource_delivery.DeliverHostResourcesHandler = .{
        .model = &client.model,
        .effects = effects(client),
    };

    try use_case.execute(commit);
}

fn effects(client: *Client) host_resource_delivery.Effects {
    return .{
        .context = client,
        .sync_graphics_fallbacks = syncGraphicsFallbacks,
        .configure_sidebar = configureSidebar,
        .invalidate_graphics_placements = invalidateGraphicsPlacements,
        .resize_presenter = resizePresenter,
        .resize_view = resizeView,
        .sync_pane_geometry = syncPaneGeometry,
    };
}

fn syncGraphicsFallbacks(raw_context: *anyopaque) void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    pane_graphics.syncFallbacks(client);
}

fn configureSidebar(raw_context: *anyopaque, configuration: host_resource_delivery.SidebarConfiguration) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try client.view.configureSidebar(
        client.sidebar_rendering,
        configuration.capabilities.kitty_graphics,
        configuration.size.cell_width_px,
        configuration.size.cell_height_px,
    );
}

fn invalidateGraphicsPlacements(raw_context: *anyopaque) void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    client.graphics_store.invalidatePlacements();
}

fn resizePresenter(raw_context: *anyopaque, size: schema.TerminalSize) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try client.presenter.resize(size.cols, size.rows);
}

fn resizeView(raw_context: *anyopaque, size: schema.TerminalSize) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try client.view.resize(size.cols, size.rows);
}

fn syncPaneGeometry(raw_context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try pane_geometry.offerActive(client, client.view.workbench());
}
