const ModelType = @import("../../model/Model.zig");
const OfferEffectsType = @import("../panes/OfferEffects.zig");
const TabSnapshotDeliveryEffects = @import("TabSnapshotDeliveryEffects.zig");
const TabReconciliationType = @import("../../model/TabReconciliation.zig");
const ReleasePaneResourcesHandlerType = @import("../panes/ReleasePaneResourcesHandler.zig");
const OfferPaneGeometryHandlerType = @import("../panes/OfferPaneGeometryHandler.zig");
const RequestPaneAttachmentsHandlerType = @import("../panes/RequestPaneAttachmentsHandler.zig");
const std = @import("std");
const TabLocationType = @import("telar-core").TabLocation;
const TabType = @import("../../workspace/Tab.zig");
const DeliverTabSnapshotHandler = @This();

model: *ModelType,
geometry_effects: OfferEffectsType,
effects: TabSnapshotDeliveryEffects,

/// Validates one exact tab reconciliation before releasing retired panes,
/// repairing active geometry and requesting each missing attachment once.
/// A detached pane the layout leaves without content is skipped, not
/// failed: the runtime owns membership and a later geometry change offers
/// the pane again.
///
/// ```zig
/// try handler.execute(&reconciliation);
/// ```
pub fn execute(handler: *DeliverTabSnapshotHandler, reconciliation: *const TabReconciliationType) !void {
    try handler.validate(reconciliation);

    var release_pane: ReleasePaneResourcesHandlerType = .{
        .model = handler.model,
        .effects = .{
            .context = handler.effects.context,
            .clear_graphics = handler.effects.clear_pane_graphics,
        },
    };
    for (reconciliation.removed_panes.slice()) |pane_id| {
        handler.effects.ignore_pane_requests(handler.effects.context, pane_id);
        _ = release_pane.execute(pane_id);
    }

    if (!reconciliation.active) {
        return;
    }

    const tab = try handler.exactTab(reconciliation.location);
    try handler.effects.synchronize_active_resources(handler.effects.context);

    var offer_geometry: OfferPaneGeometryHandlerType = .{
        .effects = handler.geometry_effects,
    };
    _ = try offer_geometry.execute(&tab.model, reconciliation.area);

    var request_attachments: RequestPaneAttachmentsHandlerType = .{
        .effects = .{
            .context = handler.effects.context,
            .attachment_pending = handler.effects.attachment_pending,
            .request_attachment = handler.effects.request_attachment,
        },
    };
    _ = try request_attachments.execute(tab, reconciliation.area);
}

fn validate(handler: *const DeliverTabSnapshotHandler, reconciliation: *const TabReconciliationType) !void {
    const tab = try handler.exactTab(reconciliation.location);
    const active = handler.model.workspace.activeConst() orelse return error.StaleTabReconciliation;
    const version = handler.model.version();
    if (reconciliation.active != std.meta.eql(active.location, reconciliation.location) or
        tab.snapshot_loaded != reconciliation.snapshot_loaded or
        tab.model.layout.currentRevision() != reconciliation.layout_revision or
        version.workspace != reconciliation.workspace_revision or
        version.tabs != reconciliation.tabs_revision or
        version.active_tab != reconciliation.active_tab_revision or
        version.panes != reconciliation.panes_revision)
    {
        return error.StaleTabReconciliation;
    }
}

fn exactTab(handler: *const DeliverTabSnapshotHandler, location: TabLocationType) !*TabType {
    const tab = handler.model.workspace.find(location.tab_id) orelse return error.StaleTabReconciliation;
    if (!std.meta.eql(tab.location, location)) {
        return error.StaleTabReconciliation;
    }

    return tab;
}
