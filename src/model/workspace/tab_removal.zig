//! A tab disappears from the client's workspace with its panes
//! (docs/flows/tab-removal.md).
const core = @import("telar-core");
const ClientModel = @import("../state/ClientModel.zig");

/// Removes one tab and its panes, keeping the active tab when it survives.
/// Removing the last tab leaves no workspace.
/// Example: `_ = tab_removal.remove(model, tab_id);`
pub fn remove(model: *ClientModel, tab_id: core.TabId) bool {
    const slot = model.tabs.find(tab_id) orelse return false;
    const active_id = model.tabs.location[model.tabs.active].tab_id;
    model.panes.removeTab(tab_id);
    model.tabs.remove(slot);
    if (model.tabs.count == 0) {
        model.tabs.active = 0;
        model.workspace = null;
        model.workspace_name_len = 0;
        return true;
    }

    model.tabs.active = model.tabs.find(active_id) orelse @min(slot, model.tabs.count - 1);
    return true;
}
