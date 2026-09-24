//! The runtime's canonical pane list for one tab reaches the client
//! (docs/flows/tab-snapshot-reconciliation.md).
const TabReconciliation = @import("../state/TabReconciliation.zig");
const tab_snapshot_reconciliation = @import("tab_snapshot_reconciliation.zig");
const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const std = @import("std");
const ClientModel = @import("../state/ClientModel.zig");
const PaneSnapshot = @import("PaneSnapshot.zig");
const DiscoveredPane = @import("DiscoveredPane.zig");
const multiplexer = @import("multiplexer.zig");
const tab_layout = @import("tab_layout.zig");

/// Reconciles canonical pane membership while keeping matching pane
/// buffers and the client's layout. Returns the tab's slot.
/// Example: `const slot = try tab_snapshot_reconciliation.reconcile(model, snapshot, area);`
pub fn reconcile(model: *ClientModel, snapshot: PaneSnapshot, area: cellgrid.Rect) !usize {
    const slot = model.tabs.find(snapshot.location.tab_id) orelse return error.UnexpectedTab;
    if (!std.meta.eql(model.tabs.location[slot], snapshot.location)) {
        return error.UnexpectedTab;
    }

    if (snapshot.panes.len > core.max_panes_per_tab) {
        return error.TooManyPanes;
    }

    for (snapshot.panes, 0..) |pane_id, index| {
        if (std.mem.findScalar(core.PaneId, snapshot.panes[0..index], pane_id) != null) {
            return error.DuplicatePane;
        }
    }

    const tab_id = snapshot.location.tab_id;
    const focused_before = model.tabs.layout[slot].focused();
    var removed: [core.max_panes_per_tab]core.PaneId = undefined;
    var removed_count: usize = 0;
    var panes = model.panes.iterateConst(tab_id);
    while (panes.next()) |pane| {
        if (std.mem.findScalar(core.PaneId, snapshot.panes, pane.id) == null) {
            removed[removed_count] = pane.id;
            removed_count += 1;
        }
    }

    for (removed[0..removed_count]) |pane_id| {
        _ = tab_layout.removePane(model, pane_id);
    }

    for (snapshot.panes) |pane_id| {
        if (model.panes.findIn(tab_id, pane_id) == null) {
            try addDiscovered(
                model,
                slot,
                .{
                    .pane_id = pane_id,
                    .location = snapshot.location,
                    .area = area,
                },
            );
        }
    }

    var focus_after = model.tabs.layout[slot].focused();
    if (focused_before) |pane_id| {
        if (std.mem.findScalar(core.PaneId, snapshot.panes, pane_id) != null) {
            focus_after = pane_id;
        }
    }

    if (focus_after) |pane_id| {
        try restoreFocus(model, slot, snapshot, pane_id);
    }

    model.tabs.restore_display_order[slot] = false;
    model.tabs.snapshot_loaded[slot] = true;
    return slot;
}

/// Adds a pane found in a runtime snapshot. Reconstructed layouts are
/// local and deterministic: each additional pane splits the focused leaf
/// left to right. The runtime owns membership, so a pane the area cannot
/// fit still joins, detached and empty until the geometry changes.
/// Example: `try tab_snapshot_reconciliation.addDiscovered(model, slot, discovered);`
pub fn addDiscovered(model: *ClientModel, slot: usize, discovered: DiscoveredPane) !void {
    if (model.panes.find(discovered.pane_id) != null) {
        return;
    }

    const layout = &model.tabs.layout[slot];
    const focused = layout.focused() orelse {
        const size = multiplexer.rectSize(discovered.area) orelse multiplexer.placeholder_size;
        _ = try model.panes.add(
            model.gpa,
            .{
                .pane_id = discovered.pane_id,
                .location = discovered.location,
                .size = size,
            },
            false,
        );
        errdefer _ = model.panes.remove(discovered.pane_id);
        try layout.addRoot(discovered.pane_id);
        return;
    };

    const prospective = tab_layout.prospectiveSplit(
        model,
        slot,
        .{
            .pane_id = focused,
            .axis = .horizontal,
        },
        discovered.area,
    );
    const size = if (prospective) |split|
        multiplexer.rectSize(split.new_content) orelse multiplexer.placeholder_size
    else
        multiplexer.placeholder_size;

    _ = try model.panes.add(
        model.gpa,
        .{
            .pane_id = discovered.pane_id,
            .location = discovered.location,
            .size = size,
        },
        false,
    );
    errdefer _ = model.panes.remove(discovered.pane_id);
    try layout.split(.{
        .existing_pane = focused,
        .new_pane = discovered.pane_id,
        .axis = .horizontal,
    });
}

fn restoreFocus(model: *ClientModel, slot: usize, snapshot: PaneSnapshot, pane_id: core.PaneId) !void {
    var restored = false;
    if (model.pending_layout_restore) |pending| {
        if (std.meta.eql(pending.location, snapshot.location)) {
            const focused = if (pending.restore_saved_focus) pending.layout.focused() orelse pane_id else pane_id;
            restored = tab_layout.restoreSaved(
                model,
                slot,
                pending.layout,
                .{
                    .ids = snapshot.panes,
                    .focused = focused,
                },
            );
            model.pending_layout_restore = null;
        }
    }

    if (restored) {
        return;
    }

    if (model.tabs.restore_display_order[slot]) {
        try tab_layout.restoreDisplayOrder(model, slot, snapshot.panes, pane_id);
    } else {
        _ = model.tabs.layout[slot].focusPane(pane_id);
    }
}

/// Commits one canonical pane list while preserving retained pane state.
/// Only visible active-tab changes advance the pane revision.
///
/// ```zig
/// const reconciliation = try reconcileTab(model, snapshot, workbench);
/// ```
pub fn reconcileTab(model: *ClientModel, snapshot: PaneSnapshot, area: cellgrid.Rect) !TabReconciliation {
    const tab = model.tabs.find(snapshot.location.tab_id) orelse return error.UnexpectedTab;
    if (!std.meta.eql(model.tabs.location[tab], snapshot.location)) {
        return error.UnexpectedTab;
    }

    if (snapshot.panes.len > core.max_panes_per_tab) {
        return error.TooManyPanes;
    }

    for (snapshot.panes, 0..) |pane_id, index| {
        if (std.mem.findScalar(core.PaneId, snapshot.panes[0..index], pane_id) != null) {
            return error.DuplicatePane;
        }

        const existing = model.panes.findConst(pane_id);
        if (existing != null and !std.meta.eql(existing.?.location, snapshot.location)) {
            return error.PaneAlreadyExists;
        }
    }

    const active_location = model.activeTabLocation() orelse return error.NoActiveTab;
    const active = std.meta.eql(active_location, snapshot.location);
    const previous_layout_revision = model.tabs.layout[tab].currentRevision();
    var reconciliation: TabReconciliation = .{
        .location = snapshot.location,
        .area = area,
        .active = active,
        .panes_changed = false,
    };
    var panes = model.panes.iterateConst(snapshot.location.tab_id);
    while (panes.next()) |pane| {
        if (std.mem.findScalar(core.PaneId, snapshot.panes, pane.id) == null) {
            reconciliation.removed_panes.append(pane.id);
        }
    }

    if (model.saved_layouts.find(snapshot.location)) |saved| {
        const already_staged = if (model.pending_layout_restore) |pending| std.meta.eql(pending.location, snapshot.location) else false;
        if (!already_staged) {
            model.pending_layout_restore = .{
                .location = snapshot.location,
                .layout = saved.layout,
                .restore_saved_focus = true,
            };
        }
    }

    const reconciled = try tab_snapshot_reconciliation.reconcile(model, snapshot, area);
    model.saved_layouts.forget(snapshot.location);
    reconciliation.panes_changed = model.tabs.layout[reconciled].currentRevision() != previous_layout_revision;
    if (reconciliation.active and reconciliation.panes_changed) {
        model.panes_revision +%= 1;
    }

    reconciliation.snapshot_loaded = model.tabs.snapshot_loaded[reconciled];
    reconciliation.layout_revision = model.tabs.layout[reconciled].currentRevision();
    reconciliation.workspace_revision = model.workspace_revision;
    reconciliation.tabs_revision = model.tabs_revision;
    reconciliation.active_tab_revision = model.active_tab_revision;
    reconciliation.panes_revision = model.panes_revision;

    return reconciliation;
}
