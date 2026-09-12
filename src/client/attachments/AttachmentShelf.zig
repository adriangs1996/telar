const types = @import("types.zig");
const TargetType = @import("AttachmentTarget.zig");
const MarkerScreenType = @import("MarkerScreen.zig");
const CaptureType = @import("Capture.zig");
const PaneBottomReservationType = @import("../workspace/PaneBottomReservation.zig");
/// The adapter-owned attachment shelf and modal: adopting captures, keeping
/// markers reconciled with the pane, and the modal's input ownership.
const AttachmentShelf = @This();

context: *anyopaque,
adopt_fn: *const fn (*anyopaque, *CaptureType) anyerror!bool,
reconcile_markers_fn: *const fn (*anyopaque, TargetType, MarkerScreenType) ?bool,
sync_target_fn: *const fn (*anyopaque, ?TargetType) bool,
remove_fn: *const fn (*anyopaque, types.Id) ?bool,
remove_prompt_fn: *const fn (*anyopaque, TargetType) ?bool,
modal_active_fn: *const fn (*anyopaque) bool,
close_modal_fn: *const fn (*anyopaque) bool,
reservation_fn: *const fn (*anyopaque) ?PaneBottomReservationType,

/// Takes ownership of one capture; reports whether the layout changed.
/// Example: `const layout_changed = try client.attachment_shelf.adopt(capture);`.
pub fn adopt(port: AttachmentShelf, capture: *CaptureType) !bool {
    return port.adopt_fn(port.context, capture);
}

pub fn reconcileMarkers(port: AttachmentShelf, target: TargetType, screen: MarkerScreenType) ?bool {
    return port.reconcile_markers_fn(port.context, target, screen);
}

pub fn syncTarget(port: AttachmentShelf, target: ?TargetType) bool {
    return port.sync_target_fn(port.context, target);
}

pub fn remove(port: AttachmentShelf, id: types.Id) ?bool {
    return port.remove_fn(port.context, id);
}

pub fn removePrompt(port: AttachmentShelf, target: TargetType) ?bool {
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
pub fn reservation(port: AttachmentShelf) ?PaneBottomReservationType {
    return port.reservation_fn(port.context);
}
