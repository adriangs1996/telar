const DeliverWorkspaceSnapshotHandler = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("workspace_snapshot_delivery.zig");
const pane_geometry_delivery = @import("../panes/root.zig").pane_geometry_delivery;
const Effects = @import("WorkspaceSnapshotDeliveryEffects.zig");
const pane_resource_release = @import("../panes/root.zig").pane_resource_release;
const pane_focus_reporting = @import("../panes/root.zig").pane_focus_reporting;
const std = @import("std");
model: *client_model.Model,
area: source_namespace.ui.Rect,
geometry_effects: pane_geometry_delivery.OfferEffects,
effects: Effects,

/// Validates one exact reconciliation before releasing retired resources,
/// activating the canonical tab and repairing snapshot or geometry state.
///
/// ```zig
/// try handler.execute(&reconciliation);
/// ```
pub fn execute(handler: *DeliverWorkspaceSnapshotHandler, reconciliation: *const client_model.WorkspaceReconciliation) !void {
    try handler.validate(reconciliation);

    for (reconciliation.removed_tabs.slice()) |location| {
        handler.effects.ignore_tab_requests(handler.effects.context, location.tab_id);
    }

    var release_pane: pane_resource_release.ReleasePaneResourcesHandler = .{
        .model = handler.model,
        .effects = .{
            .context = handler.effects.context,
            .clear_graphics = handler.effects.clear_pane_graphics,
        },
    };
    for (reconciliation.removed_panes.slice()) |pane_id| {
        _ = release_pane.execute(pane_id);
    }

    const active = handler.model.workspace.active() orelse return error.StaleWorkspaceReconciliation;
    if (reconciliation.active_tab_changed) {
        var retire_focus: pane_focus_reporting.RetireReportedPaneFocusHandler = .{
            .model = handler.model,
        };
        _ = retire_focus.execute();

        var panes = active.model.paneIterator();
        while (panes.next()) |pane| {
            try handler.effects.set_pane_graphics_visible(handler.effects.context, pane.id, true);
        }

        try handler.effects.synchronize_active_resources(handler.effects.context);
    }

    if (handler.effects.tab_snapshot_pending(handler.effects.context)) {
        return;
    }

    if (reconciliation.active_tab_changed or !reconciliation.active_snapshot_loaded) {
        try handler.effects.request_tab_snapshot(handler.effects.context, reconciliation.active);
        return;
    }

    var offer_geometry: pane_geometry_delivery.OfferPaneGeometryHandler = .{
        .effects = handler.geometry_effects,
    };
    _ = try offer_geometry.execute(&active.model, handler.area);
}

fn validate(handler: *const DeliverWorkspaceSnapshotHandler, reconciliation: *const client_model.WorkspaceReconciliation) !void {
    const active = handler.model.workspace.activeConst() orelse return error.StaleWorkspaceReconciliation;
    const version = handler.model.version();
    if (!std.meta.eql(active.location, reconciliation.active) or
        reconciliation.active_tab_changed != !std.meta.eql(reconciliation.previous_active, reconciliation.active) or
        active.snapshot_loaded != reconciliation.active_snapshot_loaded or
        version.workspace != reconciliation.workspace_revision or
        version.tabs != reconciliation.tabs_revision or
        version.active_tab != reconciliation.active_tab_revision or
        version.panes != reconciliation.panes_revision)
    {
        return error.StaleWorkspaceReconciliation;
    }
}
