//! The runtime's canonical tab list for the client's workspace arrives
//! (docs/flows/workspace-reconciliation.md).
const core = @import("telar-core");
const std = @import("std");
const Model = @import("../state/Model.zig");
const WorkspaceSnapshotInput = @import("WorkspaceSnapshotInput.zig");
const label_validation = @import("label_validation.zig");

/// Reconciles tab identity, order and labels without replacing retained
/// layouts. Validation completes before the first mutation.
/// Example: `try workspace_reconciliation.reconcileTabs(model, snapshot);`
pub fn reconcileTabs(model: *Model, snapshot: WorkspaceSnapshotInput) !void {
    try validate(model, snapshot);

    const active_id = model.tabs.location[model.tabs.activeSlot() orelse return error.WorkspaceHasNoTabs].tab_id;
    var canonical_ids: [core.max_tabs_per_workspace]core.TabId = undefined;
    for (snapshot.tabs, 0..) |descriptor, index| {
        canonical_ids[index] = descriptor.tab_id;
    }

    const canonical = canonical_ids[0..snapshot.tabs.len];
    var current = model.tabs.count;
    while (current > 0) {
        current -= 1;
        const tab_id = model.tabs.location[current].tab_id;
        if (std.mem.findScalar(core.TabId, canonical, tab_id) == null) {
            model.panes.removeTab(tab_id);
            model.tabs.remove(current);
        }
    }

    for (snapshot.tabs, 0..) |descriptor, index| {
        if (model.tabs.find(descriptor.tab_id)) |existing| {
            model.tabs.move(existing, index);
        } else {
            const location: core.TabLocation = .{
                .workspace = model.workspace.?,
                .tab_id = descriptor.tab_id,
            };
            _ = model.tabs.insert(index, location, model.pane_gaps);
        }

        model.tabs.setLabel(index, descriptor.label);
        if (model.panes.countIn(descriptor.tab_id) != descriptor.pane_count) {
            model.tabs.snapshot_loaded[index] = false;
        }
    }

    std.debug.assert(model.tabs.count == snapshot.tabs.len);
    if (model.pending_layout_restore) |pending| {
        if (std.mem.findScalar(core.TabId, canonical, pending.location.tab_id) == null) {
            model.pending_layout_restore = null;
        }
    }

    @memcpy(model.workspace_name[0..snapshot.name.len], snapshot.name);
    model.workspace_name_len = @intCast(snapshot.name.len);
    model.tabs.active = model.tabs.find(active_id) orelse 0;
}

fn validate(model: *const Model, snapshot: WorkspaceSnapshotInput) !void {
    if (model.workspace == null or !std.meta.eql(model.workspace.?, snapshot.workspace)) {
        return error.UnexpectedWorkspace;
    }

    if (snapshot.tabs.len == 0) {
        return error.WorkspaceHasNoTabs;
    }

    if (snapshot.tabs.len > core.max_tabs_per_workspace) {
        return error.TabLimitReached;
    }

    if (snapshot.name.len == 0 or snapshot.name.len > core.max_workspace_name_bytes or
        std.mem.findScalar(u8, snapshot.name, 0) != null)
    {
        return error.InvalidWorkspaceName;
    }

    for (snapshot.tabs, 0..) |descriptor, index| {
        if (descriptor.tab_id == .invalid) {
            return error.InvalidTabId;
        }

        if (descriptor.pane_count > core.max_panes_per_tab) {
            return error.TooManyPanes;
        }

        if (descriptor.label.len != 0) {
            try label_validation.validate(descriptor.label, .renamed_tab);
        }

        if (descriptor.foregrounds.len > descriptor.pane_count) {
            return error.TooManyPanes;
        }

        for (descriptor.foregrounds, 0..) |foreground, foreground_index| {
            if (foreground.pane_id == .invalid) {
                return error.InvalidPaneId;
            }

            if (foreground.name.len == 0 or foreground.name.len > core.max_foreground_name_bytes or std.mem.findScalar(u8, foreground.name, 0) != null) {
                return error.InvalidForegroundName;
            }

            for (descriptor.foregrounds[0..foreground_index]) |previous| {
                if (previous.pane_id == foreground.pane_id) {
                    return error.DuplicatePane;
                }
            }
        }

        for (snapshot.tabs[0..index]) |previous| {
            if (previous.tab_id == descriptor.tab_id) {
                return error.DuplicateTab;
            }
        }
    }
}
