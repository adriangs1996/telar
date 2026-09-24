//! Moving a pane's viewport through its scrollback.

const model_namespace = @import("../state/model_namespace.zig");
const model_data = @import("../model.zig");
const copy_mode = @import("../input/copy_mode.zig");
const ClientModel = @import("../state/ClientModel.zig");

/// Commits one viewport intent for an attached pane in the active tab.
/// Copy mode owns its viewport transaction while it is active.
///
/// ```zig
/// const change = pane_viewport.set(model, command) orelse return;
/// ```
pub fn set(model: *ClientModel, command: model_data.PaneViewportCommand) ?model_data.PaneViewportChange {
    if (copy_mode.isActive(model)) {
        return null;
    }

    const slot = model.tabs.activeSlot() orelse return null;
    const pane = model.panes.findIn(model.tabs.location[slot].tab_id, command.pane_id) orelse return null;
    if (!pane.attached) {
        return null;
    }

    return model_namespace.commitPaneViewport(model, pane, model_namespace.paneViewportOffset(pane, command.target));
}
