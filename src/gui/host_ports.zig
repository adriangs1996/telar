//! Native adapter port assembly. Capabilities own their service implementations.
const client_module = @import("telar-client");
const data = @import("model");
const core = @import("telar-core");
const chrome_module = @import("ports/chrome.zig");
const host_input = @import("ports/host_input.zig");
const worker_ports = @import("ports/workers.zig");
const GuiClient = @import("GuiClient.zig");

/// Example: `const port = graphicsRetention(app);`.
pub fn graphicsRetention(client: *client_module.AttachedClient) client_module.GraphicsRetention {
    return .{
        .context = client,
        .apply_fn = applyGraphics,
        .clear_pane_fn = clearPaneGraphics,
        .set_pane_visible_fn = setPaneGraphicsVisible,
        .pane_visible_fn = paneGraphicsVisible,
        .has_pane_graphics_fn = hasPaneGraphics,
        .ingress_version_fn = graphicsIngressVersion,
        .peek_credit_fn = peekGraphicsCredit,
        .consume_credit_fn = consumeGraphicsCredit,
    };
}

fn applyGraphics(context: *anyopaque, command: data.PaneGraphicsCommand) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    return GuiClient.of(client).applyGraphics(command);
}

fn clearPaneGraphics(context: *anyopaque, pane_id: core.PaneId) void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    GuiClient.of(client).graphics_store.clearPane(pane_id);
}

fn consumeGraphicsCredit(context: *anyopaque, credit: client_module.GraphicsCredit) void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    GuiClient.of(client).graphics_store.consumeCredit(credit);
}

fn graphicsIngressVersion(context: *anyopaque) u64 {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    return GuiClient.of(client).graphics_store.ingressVersion();
}

fn hasPaneGraphics(context: *anyopaque, pane_id: core.PaneId) bool {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    return GuiClient.of(client).graphics_store.hasPaneGraphics(pane_id);
}

fn paneGraphicsVisible(context: *anyopaque, pane_id: core.PaneId) bool {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    return GuiClient.of(client).graphics_store.paneVisible(pane_id);
}

fn peekGraphicsCredit(context: *anyopaque) ?client_module.GraphicsCredit {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    return GuiClient.of(client).graphics_store.peekCredit();
}

fn setPaneGraphicsVisible(context: *anyopaque, pane_id: core.PaneId, visible: bool) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    try GuiClient.of(client).graphics_store.setPaneVisible(pane_id, visible);
}

pub const chrome = chrome_module.port;
pub const hostInput = host_input.port;
pub const workers = worker_ports.jobs;
