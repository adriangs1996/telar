const model_data = @import("model");
const MarkerScreen = @import("MarkerScreen.zig");
const DeletionProbe = @import("DeletionProbe.zig");
/// The attachment shelf a host that draws image previews owns: the catalog
/// it instantiates from `GenericCatalog` with its own preview state, marker
/// plans over that catalog, and the preview modal's input ownership. A host
/// without previews leaves `AttachedClient.attachments` null.
const AttachmentShelf = @This();

context: *anyopaque,
adopt_fn: *const fn (*anyopaque, *model_data.Capture) anyerror!bool,
reconcile_markers_fn: *const fn (*anyopaque, model_data.AttachmentTarget, MarkerScreen) ?bool,
sync_target_fn: *const fn (*anyopaque, ?model_data.AttachmentTarget) bool,
remove_fn: *const fn (*anyopaque, model_data.AttachmentId) ?bool,
remove_prompt_fn: *const fn (*anyopaque, model_data.AttachmentTarget) ?bool,
modal_active_fn: *const fn (*anyopaque) bool,
close_modal_fn: *const fn (*anyopaque) bool,
reservation_fn: *const fn (*anyopaque) ?model_data.PaneBottomReservation,
visible_target_fn: *const fn (*anyopaque) ?model_data.AttachmentTarget,
plan_marker_removal_fn: *const fn (*anyopaque, model_data.AttachmentId, MarkerScreen) ?model_data.MarkerRemoval,
id_at_marker_deletion_fn: *const fn (*anyopaque, MarkerScreen, model_data.AttachmentMarkerDeletion) ?model_data.AttachmentId,
pending_marker_at_deletion_fn: *const fn (*anyopaque, MarkerScreen, DeletionProbe) bool,
expect_marker_deletion_fn: *const fn (*anyopaque, model_data.AttachmentTarget) void,

/// Takes ownership of one capture; reports whether the layout changed.
/// Example: `const layout_changed = try shelf.adopt(capture);`.
pub fn adopt(self: AttachmentShelf, capture: *model_data.Capture) !bool {
    return self.adopt_fn(self.context, capture);
}

pub fn reconcileMarkers(self: AttachmentShelf, target: model_data.AttachmentTarget, screen: MarkerScreen) ?bool {
    return self.reconcile_markers_fn(self.context, target, screen);
}

pub fn syncTarget(self: AttachmentShelf, target: ?model_data.AttachmentTarget) bool {
    return self.sync_target_fn(self.context, target);
}

pub fn remove(self: AttachmentShelf, id: model_data.AttachmentId) ?bool {
    return self.remove_fn(self.context, id);
}

pub fn removePrompt(self: AttachmentShelf, target: model_data.AttachmentTarget) ?bool {
    return self.remove_prompt_fn(self.context, target);
}

/// Whether the modal owns host input. Example: `if (shelf.modalActive()) ...`.
pub fn modalActive(self: AttachmentShelf) bool {
    return self.modal_active_fn(self.context);
}

pub fn closeModal(self: AttachmentShelf) bool {
    return self.close_modal_fn(self.context);
}

/// Space the shelf asks for below the pane that owns the visible previews.
pub fn reservation(self: AttachmentShelf) ?model_data.PaneBottomReservation {
    return self.reservation_fn(self.context);
}

/// Example: `const target = shelf.visibleTarget() orelse return;`.
pub fn visibleTarget(self: AttachmentShelf) ?model_data.AttachmentTarget {
    return self.visible_target_fn(self.context);
}

pub fn planMarkerRemoval(self: AttachmentShelf, id: model_data.AttachmentId, screen: MarkerScreen) ?model_data.MarkerRemoval {
    return self.plan_marker_removal_fn(self.context, id, screen);
}

pub fn idAtMarkerDeletion(self: AttachmentShelf, screen: MarkerScreen, deletion: model_data.AttachmentMarkerDeletion) ?model_data.AttachmentId {
    return self.id_at_marker_deletion_fn(self.context, screen, deletion);
}

pub fn pendingMarkerAtDeletion(self: AttachmentShelf, screen: MarkerScreen, probe: DeletionProbe) bool {
    return self.pending_marker_at_deletion_fn(self.context, screen, probe);
}

pub fn expectMarkerDeletion(self: AttachmentShelf, target: model_data.AttachmentTarget) void {
    self.expect_marker_deletion_fn(self.context, target);
}
