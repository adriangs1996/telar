//! The runtime's canonical tab list for the client's workspace arrives
//! (docs/flows/workspace-reconciliation.md).
const pane_metadata = @import("../panes/pane_metadata.zig");
const WorkspaceReconciliation = @import("../state/WorkspaceReconciliation.zig");
const workspace_reconciliation = @import("workspace_reconciliation.zig");
const tab_label = @import("tab_label.zig");
const model_namespace = @import("../state/model_namespace.zig");
const core = @import("telar-core");
const std = @import("std");
const ClientModel = @import("../state/ClientModel.zig");
const limit_reached = @import("../connection/limit_reached.zig");
const WorkspaceSnapshotInput = @import("WorkspaceSnapshotInput.zig");
const label_validation = @import("label_validation.zig");

/// Reconciles tab identity, order and labels without replacing retained
/// layouts. Validation completes before the first mutation.
/// Example: `try workspace_reconciliation.reconcileTabs(model, snapshot);`
pub fn reconcileTabs(model: *ClientModel, snapshot: WorkspaceSnapshotInput) !void {
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
            limit_reached.forgetClosedPanes(model);
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

fn validate(model: *const ClientModel, snapshot: WorkspaceSnapshotInput) !void {
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

/// Commits one canonical workspace snapshot and reports the client
/// resources that became stale. Revisions advance only for visible
/// semantic changes.
///
/// ```zig
/// const reconciliation = try workspace_reconciliation.reconcile(model, snapshot);
/// ```
pub fn reconcile(model: *ClientModel, snapshot: WorkspaceSnapshotInput) !WorkspaceReconciliation {
    const current_workspace = model.workspace orelse return error.UnexpectedWorkspace;
    if (!std.meta.eql(current_workspace, snapshot.workspace)) {
        return error.UnexpectedWorkspace;
    }

    if (snapshot.tabs.len == 0) {
        return error.WorkspaceHasNoTabs;
    }

    if (snapshot.tabs.len > core.max_tabs_per_workspace) {
        return error.TabLimitReached;
    }

    if (snapshot.name.len == 0 or snapshot.name.len > core.max_workspace_name_bytes) {
        return error.InvalidWorkspaceName;
    }

    const previous_active = model.activeTabLocation() orelse return error.NoActiveTab;
    var reconciliation: WorkspaceReconciliation = .{
        .previous_active = previous_active,
        .active = previous_active,
        .workspace_changed = !std.mem.eql(u8, model.workspaceName(), snapshot.name),
        .tabs_changed = snapshot.tabs.len != model.tabs.count,
    };
    var canonical_tabs: [core.max_tabs_per_workspace]core.TabId = undefined;
    for (snapshot.tabs, 0..) |descriptor, index| {
        canonical_tabs[index] = descriptor.tab_id;
        if (index >= model.tabs.count) {
            reconciliation.tabs_changed = true;
        } else {
            if (model.tabs.location[index].tab_id != descriptor.tab_id or
                !std.mem.eql(u8, model.tabs.canonicalLabel(index), descriptor.label))
            {
                reconciliation.tabs_changed = true;
            }
        }
    }

    for (model.tabs.location[0..model.tabs.count]) |location| {
        if (std.mem.findScalar(core.TabId, canonical_tabs[0..snapshot.tabs.len], location.tab_id) != null) {
            continue;
        }

        reconciliation.removed_tabs.append(location);
        var panes = model.panes.iterateConst(location.tab_id);
        while (panes.next()) |pane| {
            reconciliation.removed_panes.append(pane.id);
        }
    }

    try workspace_reconciliation.reconcileTabs(model, snapshot);
    for (snapshot.tabs) |descriptor| {
        const slot = model.tabs.find(descriptor.tab_id).?;
        for (descriptor.foregrounds) |foreground| {
            if (model.panes.findIn(descriptor.tab_id, foreground.pane_id) != null) {
                _ = try pane_metadata.update(model, .{ .foreground = .{ .pane_id = foreground.pane_id, .name = foreground.name } });
            }
        }

        const location = model.tabs.location[slot];
        const saved_focus = if (model.saved_layouts.find(location)) |saved| saved.pane_id else null;
        if (tab_label.applyForegroundSnapshot(model, slot, descriptor.foregrounds, saved_focus)) {
            reconciliation.tabs_changed = true;
        }
    }

    reconciliation.active = model.activeTabLocation() orelse return error.WorkspaceHasNoTabs;
    reconciliation.active_tab_changed = !std.meta.eql(previous_active, reconciliation.active);

    if (reconciliation.workspace_changed) {
        model.workspace_revision +%= 1;
    }

    if (reconciliation.tabs_changed) {
        model.tabs_revision +%= 1;
    }

    if (reconciliation.active_tab_changed) {
        model.active_tab_revision +%= 1;
    }
    model_namespace.releaseInvalidCopyMode(model);

    const active = model.tabs.activeSlot() orelse return error.WorkspaceHasNoTabs;
    reconciliation.active_snapshot_loaded = model.tabs.snapshot_loaded[active];
    reconciliation.workspace_revision = model.workspace_revision;
    reconciliation.tabs_revision = model.tabs_revision;
    reconciliation.active_tab_revision = model.active_tab_revision;
    reconciliation.panes_revision = model.panes_revision;

    return reconciliation;
}
