//! Native adapter port assembly. Capabilities own their service implementations.
const client_module = @import("telar-client");
const data = @import("model");
const core = @import("telar-core");

const Store = client_module.retained_graphics.Store;

fn store(context: *anyopaque) *Store {
    return @ptrCast(@alignCast(context));
}

pub fn applyGraphics(context: *anyopaque, command: data.PaneGraphicsCommand) !void {
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

pub fn clearPaneGraphics(context: *anyopaque, pane_id: core.PaneId) void {
    store(context).clearPane(pane_id);
}

pub fn consumeGraphicsCredit(context: *anyopaque, credit: client_module.GraphicsCredit) void {
    store(context).consumeCredit(credit);
}

pub fn graphicsIngressVersion(context: *anyopaque) u64 {
    return store(context).ingressVersion();
}

pub fn hasPaneGraphics(context: *anyopaque, pane_id: core.PaneId) bool {
    return store(context).hasPaneGraphics(pane_id);
}

pub fn paneGraphicsVisible(context: *anyopaque, pane_id: core.PaneId) bool {
    return store(context).paneVisible(pane_id);
}

pub fn peekGraphicsCredit(context: *anyopaque) ?client_module.GraphicsCredit {
    return store(context).peekCredit();
}

pub fn setPaneGraphicsVisible(context: *anyopaque, pane_id: core.PaneId, visible: bool) !void {
    try store(context).setPaneVisible(pane_id, visible);
}
