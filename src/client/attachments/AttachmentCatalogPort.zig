const model_data = @import("model");
const MarkerScreenType = @import("MarkerScreen.zig");
const DeletionProbeType = @import("DeletionProbe.zig");
/// Reads and marker plans over the attachment catalog the adapter owns. The
/// adapter instantiates the shared `GenericCatalog` with its own preview state.
const AttachmentCatalogPort = @This();

context: *anyopaque,
visible_target_fn: *const fn (*anyopaque) ?model_data.AttachmentTarget,
plan_marker_removal_fn: *const fn (*anyopaque, model_data.AttachmentId, MarkerScreenType) ?model_data.MarkerRemoval,
id_at_marker_deletion_fn: *const fn (*anyopaque, MarkerScreenType, model_data.AttachmentMarkerDeletion) ?model_data.AttachmentId,
pending_marker_at_deletion_fn: *const fn (*anyopaque, MarkerScreenType, DeletionProbeType) bool,
expect_marker_deletion_fn: *const fn (*anyopaque, model_data.AttachmentTarget) void,

/// Example: `const target = client.attachment_catalog.visibleTarget() orelse return;`.
pub fn visibleTarget(port: AttachmentCatalogPort) ?model_data.AttachmentTarget {
    return port.visible_target_fn(port.context);
}

pub fn planMarkerRemoval(port: AttachmentCatalogPort, id: model_data.AttachmentId, screen: MarkerScreenType) ?model_data.MarkerRemoval {
    return port.plan_marker_removal_fn(port.context, id, screen);
}

pub fn idAtMarkerDeletion(port: AttachmentCatalogPort, screen: MarkerScreenType, deletion: model_data.AttachmentMarkerDeletion) ?model_data.AttachmentId {
    return port.id_at_marker_deletion_fn(port.context, screen, deletion);
}

pub fn pendingMarkerAtDeletion(port: AttachmentCatalogPort, screen: MarkerScreenType, probe: DeletionProbeType) bool {
    return port.pending_marker_at_deletion_fn(port.context, screen, probe);
}

pub fn expectMarkerDeletion(port: AttachmentCatalogPort, target: model_data.AttachmentTarget) void {
    port.expect_marker_deletion_fn(port.context, target);
}
