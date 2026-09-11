//! Adapts committed host-resource commands to one concrete client.

const Client = @import("../../Client.zig");
const HostCommitType = @import("telar-client").HostCommit;
const DeliverHostResourcesHandlerType = @import("telar-client").DeliverHostResourcesHandler;
const HostResourceDeliveryEffects = @import("telar-client").HostResourceDeliveryEffects;
const TerminalColorsType = @import("telar-core").TerminalColors;
const runtime_transport = @import("../../entrypoints/runtime_io.zig");
const HostAppearanceType = @import("telar-client").HostAppearance;
const pane_graphics = @import("../panes/pane_graphics.zig");
const SidebarConfigurationType = @import("telar-client").SidebarConfiguration;
const kitty_delivery = @import("../../../graphics/kitty_delivery.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const pane_geometry = @import("../panes/pane_geometry.zig");
const tab_snapshots = @import("../tabs/tab_snapshots.zig");

/// Delivers every disposable resource implied by one current host commit.
///
/// ```zig
/// try deliver(client, commit);
/// ```
pub fn deliver(client: *Client, commit: HostCommitType) !void {
    var use_case: DeliverHostResourcesHandlerType = .{
        .model = &client.model,
        .effects = effects(client),
    };

    try use_case.execute(commit);
}

fn effects(client: *Client) HostResourceDeliveryEffects {
    return .{
        .context = client,
        .sync_graphics_fallbacks = syncGraphicsFallbacks,
        .configure_sidebar = configureSidebar,
        .invalidate_graphics_placements = invalidateGraphicsPlacements,
        .resize_presenter = resizePresenter,
        .resize_view = resizeView,
        .sync_pane_geometry = syncPaneGeometry,
        .apply_appearance = applyAppearance,
        .sync_terminal_colors = syncTerminalColors,
    };
}

fn syncTerminalColors(raw_context: *anyopaque, colors: TerminalColorsType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    if (client.startup.phase != .opening and client.startup.phase != .active) {
        return;
    }

    try runtime_transport.enqueue(client, .{ .configure_terminal_colors = colors });
}

fn applyAppearance(raw_context: *anyopaque, appearance: HostAppearanceType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    if (client.options.theme_locked) {
        return;
    }
    const theme = switch (appearance) {
        .unknown => return,
        .light => client.appearance_themes.light orelse return,
        .dark => client.appearance_themes.dark orelse return,
    };

    client.view.setTheme(theme);
}

fn syncGraphicsFallbacks(raw_context: *anyopaque) void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    pane_graphics.syncFallbacks(client);
}

fn configureSidebar(raw_context: *anyopaque, configuration: SidebarConfigurationType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try client.view.configureSidebar(
        client.sidebar_rendering,
        .{
            .support = configuration.capabilities.images,
            .cell_width = configuration.size.cell_width_px,
            .cell_height = configuration.size.cell_height_px,
        },
    );
}

fn invalidateGraphicsPlacements(raw_context: *anyopaque) void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    kitty_delivery.invalidatePlacements(&client.graphics_store);
}

fn resizePresenter(raw_context: *anyopaque, size: TerminalSizeType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try client.presenter.resize(size.cols, size.rows);
}

fn resizeView(raw_context: *anyopaque, size: TerminalSizeType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try client.view.resize(size.cols, size.rows);
}

fn syncPaneGeometry(raw_context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try pane_geometry.offerActive(client, client.geometry().area);
    try tab_snapshots.attachActive(client, client.geometry().area);
}
