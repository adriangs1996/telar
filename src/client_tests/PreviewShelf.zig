//! A window's image preview shelf without the window, for the integration
//! tests: the shared attachment catalog with no host resources behind its
//! slots, so clipboard adoption and the preview modal run as they do under
//! an adapter that draws previews.
const data = @import("model");
const client_module = @import("telar-client");
const PreviewShelf = @This();

catalog: PreviewCatalog,
/// Whether the shelf asks for rows below its pane, as an adapter that draws
/// previews does.
reserves_rows: bool = true,

/// Example: `var shelf: PreviewShelf = .{ .catalog = .init(gpa) }; client.attachments = shelf.port();`
pub fn port(self: *PreviewShelf) client_module.AttachmentShelf {
    return .{
        .context = self,
        .adopt_fn = adoptPreview,
        .reconcile_markers_fn = reconcilePreviewMarkers,
        .sync_target_fn = syncPreviewTarget,
        .remove_fn = removePreview,
        .remove_prompt_fn = removePromptPreviews,
        .modal_active_fn = previewModalActive,
        .close_modal_fn = closePreviewModal,
        .reservation_fn = previewReservation,
        .visible_target_fn = visiblePreviewTarget,
        .plan_marker_removal_fn = planPreviewMarkerRemoval,
        .id_at_marker_deletion_fn = previewAtMarkerDeletion,
        .pending_marker_at_deletion_fn = pendingPreviewMarkerAtDeletion,
        .expect_marker_deletion_fn = expectPreviewMarkerDeletion,
    };
}

pub const PreviewCatalog = client_module.GenericCatalog(PreviewDelivery);

/// Slot delivery for the stand-in shelf: nothing is sent to a host, so every
/// slot can be released at once.
const PreviewDelivery = struct {
    pub const SlotState = struct {};
    pub const State = struct {};

    pub fn createSlot(_: *PreviewCatalog) !SlotState {
        return .{};
    }

    pub fn targetChanged(_: *PreviewCatalog) void {}

    pub fn retireSlot(_: *PreviewCatalog, _: usize) void {}

    pub fn canRelease(_: *const PreviewCatalog.Slot) bool {
        return true;
    }
};

/// Rows the stand-in shelf asks for below its pane, as the terminal shelf did.
const preview_shelf_height: u16 = 6;
const preview_shelf_minimum_height: u16 = 3;
const preview_pane_minimum_height: u16 = 3;

fn previewShelf(context: *anyopaque) *PreviewShelf {
    return @ptrCast(@alignCast(context));
}

fn adoptPreview(context: *anyopaque, capture: *data.Capture) anyerror!bool {
    const catalog = &previewShelf(context).catalog;
    const had_items = catalog.hasVisibleItems();
    try catalog.adopt(capture);

    return had_items != catalog.hasVisibleItems();
}

fn reconcilePreviewMarkers(context: *anyopaque, target: data.AttachmentTarget, screen: client_module.MarkerScreen) ?bool {
    const catalog = &previewShelf(context).catalog;
    const had_items = catalog.hasVisibleItems();
    if (catalog.reconcileMarkers(target, screen) == 0) {
        return null;
    }

    return had_items != catalog.hasVisibleItems();
}

fn syncPreviewTarget(context: *anyopaque, target: ?data.AttachmentTarget) bool {
    const change = previewShelf(context).catalog.setTarget(target);

    return change.changed and change.layout_changed;
}

fn removePreview(context: *anyopaque, id: data.AttachmentId) ?bool {
    const catalog = &previewShelf(context).catalog;
    const had_items = catalog.hasVisibleItems();
    if (!catalog.remove(id)) {
        return null;
    }

    return had_items != catalog.hasVisibleItems();
}

fn removePromptPreviews(context: *anyopaque, target: data.AttachmentTarget) ?bool {
    const catalog = &previewShelf(context).catalog;
    const had_items = catalog.hasVisibleItems();
    if (catalog.removeVisible(target) == 0) {
        return null;
    }

    return had_items != catalog.hasVisibleItems();
}

fn previewModalActive(context: *anyopaque) bool {
    return previewShelf(context).catalog.hasModal();
}

fn closePreviewModal(context: *anyopaque) bool {
    return previewShelf(context).catalog.closeModal();
}

fn previewReservation(context: *anyopaque) ?data.PaneBottomReservation {
    const shelf = previewShelf(context);
    if (!shelf.reserves_rows) {
        return null;
    }

    const target = shelf.catalog.visibleTarget() orelse return null;

    return .{
        .pane_id = target.pane_id,
        .preferred_height = preview_shelf_height,
        .minimum_height = preview_shelf_minimum_height,
        .minimum_pane_height = preview_pane_minimum_height,
    };
}

fn visiblePreviewTarget(context: *anyopaque) ?data.AttachmentTarget {
    return previewShelf(context).catalog.visibleTarget();
}

fn planPreviewMarkerRemoval(context: *anyopaque, id: data.AttachmentId, screen: client_module.MarkerScreen) ?data.MarkerRemoval {
    return previewShelf(context).catalog.planMarkerRemoval(id, screen);
}

fn previewAtMarkerDeletion(context: *anyopaque, screen: client_module.MarkerScreen, deletion: data.AttachmentMarkerDeletion) ?data.AttachmentId {
    return previewShelf(context).catalog.idAtMarkerDeletion(screen, deletion);
}

fn pendingPreviewMarkerAtDeletion(context: *anyopaque, screen: client_module.MarkerScreen, probe: client_module.DeletionProbe) bool {
    return previewShelf(context).catalog.pendingMarkerAtDeletion(screen, probe);
}

fn expectPreviewMarkerDeletion(context: *anyopaque, target: data.AttachmentTarget) void {
    previewShelf(context).catalog.expectMarkerDeletion(target);
}
