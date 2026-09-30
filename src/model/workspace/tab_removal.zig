//! A tab disappears from the client's workspace with its panes
//! (docs/flows/tab-removal.md).
const RemoveTab = @import("../state/RemoveTab.zig");
const std = @import("std");
const tab_removal = @import("tab_removal.zig");
const model_namespace = @import("../state/model_namespace.zig");
const model_data = @import("../model.zig");
const core = @import("telar-core");
const ClientModel = @import("../state/ClientModel.zig");
const limit_reached = @import("../connection/limit_reached.zig");
const TabRemoval = @import("../state/TabRemoval.zig");
const StaleTabRemoval = @import("../state/StaleTabRemoval.zig");

/// Removes one tab and its panes, keeping the active tab when it survives.
/// Removing the last tab leaves no workspace.
/// Example: `_ = tab_removal.remove(model, tab_id);`
pub fn remove(model: *ClientModel, tab_id: core.TabId) bool {
    const slot = model.tabs.find(tab_id) orelse return false;
    const active_id = model.tabs.location[model.tabs.active].tab_id;
    model.panes.removeTab(tab_id);
    limit_reached.forgetClosedPanes(model);
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

/// Removes a runtime-confirmed tab after validating workspace closure and
/// captures missing workspace or tab identities as an exact stale commit.
///
/// ```zig
/// const commit = try tab_removal.commitRemoval(model, command);
/// ```
pub fn commitRemoval(model: *ClientModel, command: RemoveTab) !TabRemovalCommit {
    const workspace = model.workspace orelse
        return staleRemoval(model, command.location, .workspace);
    if (!std.meta.eql(workspace, command.location.workspace)) {
        return staleRemoval(model, command.location, .workspace);
    }

    const closing = model.tabs.find(command.location.tab_id) orelse
        return staleRemoval(model, command.location, .tab);
    if (!std.meta.eql(model.tabs.location[closing], command.location)) {
        return error.UnexpectedTab;
    }

    const workspace_removed = model.tabs.count == 1;
    if (workspace_removed != command.workspace_removed) {
        return error.UnexpectedWorkspaceRemoval;
    }

    const was_active = model.tabs.active == closing;
    const active_tab_revision_before = model.active_tab_revision;
    var panes: model_data.RemovedPanes = .{};
    var iterator = model.panes.iterateConst(command.location.tab_id);
    while (iterator.next()) |pane| {
        panes.append(pane.id);
    }

    _ = tab_removal.remove(model, command.location.tab_id);
    const active = model.activeTabLocation();
    model.tabs_revision +%= 1;
    if (was_active) {
        model.active_tab_revision +%= 1;
    }
    model_namespace.releaseInvalidCopyMode(model);

    return .{ .removed = .{
        .removed = command.location,
        .panes = panes,
        .was_active = was_active,
        .active = active,
        .workspace_removed = workspace_removed,
        .active_layout_revision = if (model.tabs.activeSlot()) |slot|
            model.tabs.layout[slot].currentRevision()
        else
            0,
        .active_tab_revision_before = active_tab_revision_before,
        .workspace_revision = model.workspace_revision,
        .tabs_revision = model.tabs_revision,
        .active_tab_revision = model.active_tab_revision,
        .panes_revision = model.panes_revision,
        .copy_revision = model.copy_revision,
    } };
}

fn staleRemoval(model: *const ClientModel, location: core.TabLocation, absence: model_data.TabRemovalAbsence) TabRemovalCommit {
    return .{ .stale = .{
        .location = location,
        .absence = absence,
        .workspace_revision = model.workspace_revision,
        .tabs_revision = model.tabs_revision,
        .active_tab_revision = model.active_tab_revision,
        .panes_revision = model.panes_revision,
        .copy_revision = model.copy_revision,
    } };
}

const TabRemovalCommit = union(enum) {
    removed: TabRemoval,
    stale: StaleTabRemoval,
};
