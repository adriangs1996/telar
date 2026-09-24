//! The client makes one tab active (docs/flows/tab-selection.md).
const tab_selection = @import("tab_selection.zig");
const model_namespace = @import("../state/model_namespace.zig");
const model_data = @import("../model.zig");
const core = @import("telar-core");
const ClientModel = @import("../state/ClientModel.zig");

/// Example: `if (tab_selection.select(model, tab_id)) redraw();`
pub fn select(model: *ClientModel, tab_id: core.TabId) bool {
    const slot = model.tabs.find(tab_id) orelse return false;
    return selectPosition(model, slot);
}

/// Moves the active tab by `offset`, wrapping around.
/// Example: `_ = tab_selection.selectOffset(model, -1);`
pub fn selectOffset(model: *ClientModel, offset: isize) bool {
    if (model.tabs.count < 2) {
        return false;
    }

    const count: isize = @intCast(model.tabs.count);
    const wrapped: usize = @intCast(@mod(offset, count));
    return selectPosition(model, (model.tabs.active + wrapped) % model.tabs.count);
}

/// Example: `_ = tab_selection.selectPosition(model, 0);`
pub fn selectPosition(model: *ClientModel, position: usize) bool {
    if (position >= model.tabs.count or position == model.tabs.active) {
        return false;
    }

    model.tabs.active = position;
    return true;
}

/// Resolves one semantic target and returns the committed identity change.
///
/// ```zig
/// const selection = try commitSelection(model, .{ .position = 1 }) orelse return;
/// ```
pub fn commitSelection(model: *ClientModel, target: model_data.TabSelectionTarget) !?model_data.TabSelection {
    const previous = model.tabs.activeSlot() orelse return error.NoActiveTab;
    const previous_location = model.tabs.location[previous];
    const previous_layout_revision = model.tabs.layout[previous].currentRevision();

    const changed = switch (target) {
        .tab_id => |tab_id| changed: {
            const position = model.tabs.find(tab_id) orelse return error.TabNotFound;

            break :changed tab_selection.selectPosition(model, position);
        },
        .offset => |offset| tab_selection.selectOffset(model, offset),
        .position => |position| tab_selection.selectPosition(model, position),
    };
    if (!changed) {
        return null;
    }

    const selected = model.tabs.active;
    model.active_tab_revision +%= 1;
    model_namespace.releaseInvalidCopyMode(model);

    return .{
        .previous = previous_location,
        .selected = model.tabs.location[selected],
        .previous_layout_revision = previous_layout_revision,
        .selected_layout_revision = model.tabs.layout[selected].currentRevision(),
        .workspace_revision = model.workspace_revision,
        .tabs_revision = model.tabs_revision,
        .active_tab_revision = model.active_tab_revision,
        .panes_revision = model.panes_revision,
        .copy_revision = model.copy_revision,
    };
}
