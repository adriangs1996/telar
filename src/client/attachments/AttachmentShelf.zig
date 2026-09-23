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
pub fn adopt(port: AttachmentShelf, capture: *model_data.Capture) !bool {
    return port.adopt_fn(port.context, capture);
}

pub fn reconcileMarkers(port: AttachmentShelf, target: model_data.AttachmentTarget, screen: MarkerScreen) ?bool {
    return port.reconcile_markers_fn(port.context, target, screen);
}

pub fn syncTarget(port: AttachmentShelf, target: ?model_data.AttachmentTarget) bool {
    return port.sync_target_fn(port.context, target);
}

pub fn remove(port: AttachmentShelf, id: model_data.AttachmentId) ?bool {
    return port.remove_fn(port.context, id);
}

pub fn removePrompt(port: AttachmentShelf, target: model_data.AttachmentTarget) ?bool {
    return port.remove_prompt_fn(port.context, target);
}

/// Whether the modal owns host input. Example: `if (shelf.modalActive()) ...`.
pub fn modalActive(port: AttachmentShelf) bool {
    return port.modal_active_fn(port.context);
}

pub fn closeModal(port: AttachmentShelf) bool {
    return port.close_modal_fn(port.context);
}

/// Space the shelf asks for below the pane that owns the visible previews.
pub fn reservation(port: AttachmentShelf) ?model_data.PaneBottomReservation {
    return port.reservation_fn(port.context);
}

/// Example: `const target = shelf.visibleTarget() orelse return;`.
pub fn visibleTarget(port: AttachmentShelf) ?model_data.AttachmentTarget {
    return port.visible_target_fn(port.context);
}

pub fn planMarkerRemoval(port: AttachmentShelf, id: model_data.AttachmentId, screen: MarkerScreen) ?model_data.MarkerRemoval {
    return port.plan_marker_removal_fn(port.context, id, screen);
}

pub fn idAtMarkerDeletion(port: AttachmentShelf, screen: MarkerScreen, deletion: model_data.AttachmentMarkerDeletion) ?model_data.AttachmentId {
    return port.id_at_marker_deletion_fn(port.context, screen, deletion);
}

pub fn pendingMarkerAtDeletion(port: AttachmentShelf, screen: MarkerScreen, probe: DeletionProbe) bool {
    return port.pending_marker_at_deletion_fn(port.context, screen, probe);
}

pub fn expectMarkerDeletion(port: AttachmentShelf, target: model_data.AttachmentTarget) void {
    port.expect_marker_deletion_fn(port.context, target);
}
