const model_data = @import("model");
const MarkerScreenType = @import("MarkerScreen.zig");
const CaptureType = @import("Capture.zig");
/// The adapter-owned attachment shelf and modal: adopting captures, keeping
/// markers reconciled with the pane, and the modal's input ownership.
const AttachmentShelf = @This();

context: *anyopaque,
adopt_fn: *const fn (*anyopaque, *CaptureType) anyerror!bool,
reconcile_markers_fn: *const fn (*anyopaque, model_data.AttachmentTarget, MarkerScreenType) ?bool,
sync_target_fn: *const fn (*anyopaque, ?model_data.AttachmentTarget) bool,
remove_fn: *const fn (*anyopaque, model_data.AttachmentId) ?bool,
remove_prompt_fn: *const fn (*anyopaque, model_data.AttachmentTarget) ?bool,
modal_active_fn: *const fn (*anyopaque) bool,
close_modal_fn: *const fn (*anyopaque) bool,
reservation_fn: *const fn (*anyopaque) ?model_data.PaneBottomReservation,

/// Takes ownership of one capture; reports whether the layout changed.
/// Example: `const layout_changed = try client.attachment_shelf.adopt(capture);`.
pub fn adopt(port: AttachmentShelf, capture: *CaptureType) !bool {
    return port.adopt_fn(port.context, capture);
}

pub fn reconcileMarkers(port: AttachmentShelf, target: model_data.AttachmentTarget, screen: MarkerScreenType) ?bool {
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

/// Whether the modal owns host input. Example: `if (client.attachment_shelf.modalActive()) ...`.
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
