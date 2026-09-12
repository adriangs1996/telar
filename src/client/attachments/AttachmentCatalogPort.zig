const types = @import("types.zig");
const TargetType = @import("AttachmentTarget.zig");
const MarkerScreenType = @import("MarkerScreen.zig");
const MarkerRemovalType = @import("MarkerRemoval.zig");
const DeletionProbeType = @import("DeletionProbe.zig");
/// Reads and marker plans over the attachment catalog the adapter owns. The
/// adapter instantiates the shared `GenericCatalog` with its own preview state.
const AttachmentCatalogPort = @This();

context: *anyopaque,
visible_target_fn: *const fn (*anyopaque) ?TargetType,
plan_marker_removal_fn: *const fn (*anyopaque, types.Id, MarkerScreenType) ?MarkerRemovalType,
id_at_marker_deletion_fn: *const fn (*anyopaque, MarkerScreenType, types.MarkerDeletion) ?types.Id,
pending_marker_at_deletion_fn: *const fn (*anyopaque, MarkerScreenType, DeletionProbeType) bool,
expect_marker_deletion_fn: *const fn (*anyopaque, TargetType) void,

/// Example: `const target = client.attachment_catalog.visibleTarget() orelse return;`.
pub fn visibleTarget(port: AttachmentCatalogPort) ?TargetType {
    return port.visible_target_fn(port.context);
}

pub fn planMarkerRemoval(port: AttachmentCatalogPort, id: types.Id, screen: MarkerScreenType) ?MarkerRemovalType {
    return port.plan_marker_removal_fn(port.context, id, screen);
}

pub fn idAtMarkerDeletion(port: AttachmentCatalogPort, screen: MarkerScreenType, deletion: types.MarkerDeletion) ?types.Id {
    return port.id_at_marker_deletion_fn(port.context, screen, deletion);
}

pub fn pendingMarkerAtDeletion(port: AttachmentCatalogPort, screen: MarkerScreenType, probe: DeletionProbeType) bool {
    return port.pending_marker_at_deletion_fn(port.context, screen, probe);
}

pub fn expectMarkerDeletion(port: AttachmentCatalogPort, target: TargetType) void {
    port.expect_marker_deletion_fn(port.context, target);
}
