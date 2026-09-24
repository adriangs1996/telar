//! Restoring the tab layouts a client saved.

const SavedLayouts = @import("SavedLayouts.zig");
const ClientModel = @import("../state/ClientModel.zig");

/// Installs validated reconnect layouts before the initial pane arrives.
/// Example: `client_layout_persistence.restore(model, layouts);`.
pub fn restore(model: *ClientModel, layouts: SavedLayouts) void {
    model.saved_layouts = layouts;
}
