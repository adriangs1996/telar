//! Native adapter port assembly. Capabilities own their service implementations.
const client_module = @import("telar-client");
const data = @import("model");
const core = @import("telar-core");
const chrome_module = @import("ports/chrome.zig");
const host_input = @import("ports/host_input.zig");
const GuiAdapter = @import("GuiAdapter.zig");

const Store = client_module.retained_graphics.Store;

/// The graphics port of the client in `slot`: it keeps that client's images
/// in the slot's own store, so two machines' panes with one id never touch
/// each other's images.
///
/// ```zig
/// app.graphics = host_ports.graphicsRetention(gui, slot);
/// ```
pub fn graphicsRetention(gui: *GuiAdapter, slot: u8) client_module.GraphicsRetention {
    return .{
        .context = &gui.graphics_stores[slot],
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

fn store(context: *anyopaque) *Store {
    return @ptrCast(@alignCast(context));
}

fn applyGraphics(context: *anyopaque, command: data.PaneGraphicsCommand) !void {
    const graphics = store(context);
    return switch (command) {
        .snapshot => |value| graphics.applySnapshot(value),
        .image => |value| graphics.applyImage(value),
        .shared_image => |value| graphics.applySharedImage(value),
        .image_chunk => |value| graphics.applyChunk(value),
        .placement => |value| graphics.applyPlacement(value),
        .delete_image => |value| graphics.deleteImage(value),
        .delete_placement => |value| graphics.deletePlacement(value),
    };
}

fn clearPaneGraphics(context: *anyopaque, pane_id: core.PaneId) void {
    store(context).clearPane(pane_id);
}

fn consumeGraphicsCredit(context: *anyopaque, credit: client_module.GraphicsCredit) void {
    store(context).consumeCredit(credit);
}

fn graphicsIngressVersion(context: *anyopaque) u64 {
    return store(context).ingressVersion();
}

fn hasPaneGraphics(context: *anyopaque, pane_id: core.PaneId) bool {
    return store(context).hasPaneGraphics(pane_id);
}

fn paneGraphicsVisible(context: *anyopaque, pane_id: core.PaneId) bool {
    return store(context).paneVisible(pane_id);
}

fn peekGraphicsCredit(context: *anyopaque) ?client_module.GraphicsCredit {
    return store(context).peekCredit();
}

fn setPaneGraphicsVisible(context: *anyopaque, pane_id: core.PaneId, visible: bool) !void {
    try store(context).setPaneVisible(pane_id, visible);
}

pub const chrome = chrome_module.port;
pub const hostInput = host_input.port;
