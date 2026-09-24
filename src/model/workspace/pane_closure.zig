//! Closing a pane and retiring it from the model.

const std = @import("std");
const tab_layout = @import("tab_layout.zig");
const model_data = @import("../model.zig");
const core = @import("telar-core");
const ClientModel = @import("../state/ClientModel.zig");

/// Resolves the active attached pane that an explicit close request may
/// target without changing client state.
///
/// ```zig
/// const closure = pane_closure.plan(model) orelse return;
/// ```
pub fn plan(model: *const ClientModel) ?model_data.PaneClosure {
    const slot = model.tabs.activeSlot() orelse return null;
    const location = model.tabs.location[slot];
    const focused = tab_layout.focusedPaneConst(model, slot) orelse return null;
    if (!focused.attached or !std.meta.eql(focused.location, location)) {
        return null;
    }

    return .{ .pane_id = focused.id, .location = location };
}

/// Applies one authoritative pane exit. Missing identities are stale
/// lifecycle traffic and leave every presentation revision unchanged.
///
/// ```zig
/// const transition = pane_closure.retire(model, pane_id);
/// ```
pub fn retire(model: *ClientModel, pane_id: core.PaneId) model_data.PaneExit {
    const pane = model.panes.find(pane_id) orelse return staleExit(model, pane_id);
    const tab = model.tabs.find(pane.location.tab_id) orelse return staleExit(model, pane_id);
    const location = model.tabs.location[tab];
    if (!std.meta.eql(pane.location, location)) {
        return staleExit(model, pane_id);
    }

    const active = if (model.activeTabLocation()) |current|
        std.meta.eql(current, location)
    else
        false;
    _ = tab_layout.removePane(model, pane_id);
    if (active) {
        model.panes_revision +%= 1;
    }

    return .{ .retired = .{
        .pane_id = pane_id,
        .location = location,
        .active = active,
        .tab_empty = model.panes.countIn(location.tab_id) == 0,
        .layout_revision = model.tabs.layout[tab].currentRevision(),
        .workspace_revision = model.workspace_revision,
        .tabs_revision = model.tabs_revision,
        .active_tab_revision = model.active_tab_revision,
        .panes_revision = model.panes_revision,
    } };
}

fn staleExit(model: *const ClientModel, pane_id: core.PaneId) model_data.PaneExit {
    return .{ .stale = .{
        .pane_id = pane_id,
        .workspace_revision = model.workspace_revision,
        .tabs_revision = model.tabs_revision,
        .active_tab_revision = model.active_tab_revision,
        .panes_revision = model.panes_revision,
    } };
}
