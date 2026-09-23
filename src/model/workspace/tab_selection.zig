//! The client makes one tab active (docs/flows/tab-selection.md).
const core = @import("telar-core");
const Model = @import("../state/Model.zig");

/// Example: `if (tab_selection.select(model, tab_id)) redraw();`
pub fn select(model: *Model, tab_id: core.TabId) bool {
    const slot = model.tabs.find(tab_id) orelse return false;
    return selectPosition(model, slot);
}

/// Moves the active tab by `offset`, wrapping around.
/// Example: `_ = tab_selection.selectOffset(model, -1);`
pub fn selectOffset(model: *Model, offset: isize) bool {
    if (model.tabs.count < 2) {
        return false;
    }

    const count: isize = @intCast(model.tabs.count);
    const wrapped: usize = @intCast(@mod(offset, count));
    return selectPosition(model, (model.tabs.active + wrapped) % model.tabs.count);
}

/// Example: `_ = tab_selection.selectPosition(model, 0);`
pub fn selectPosition(model: *Model, position: usize) bool {
    if (position >= model.tabs.count or position == model.tabs.active) {
        return false;
    }

    model.tabs.active = position;
    return true;
}
