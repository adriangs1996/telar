//! Application use case for reconciling runtime pane graphics.

const SnapshotType = @import("telar-core").Snapshot;
const ImageType = @import("telar-core").SchemaImage;
const SharedImageType = @import("telar-core").SharedImage;
const ImageChunkType = @import("telar-core").ImageChunk;
const PlacementType = @import("telar-core").SchemaPlacement;
const DeleteImageType = @import("telar-core").DeleteImage;
const DeletePlacementType = @import("telar-core").DeletePlacement;
const PaneIdType = @import("telar-core").PaneId;
const ResourceState = @import("ResourceState.zig");
const Applied = @import("Applied.zig");

pub const Command = union(enum) {
    snapshot: SnapshotType,
    image: ImageType,
    shared_image: SharedImageType,
    image_chunk: ImageChunkType,
    placement: PlacementType,
    delete_image: DeleteImageType,
    delete_placement: DeletePlacementType,

    /// Returns the pane identity carried by every graphics command.
    ///
    /// ```zig
    /// const pane_id = command.paneId();
    /// ```
    pub fn paneId(command: Command) PaneIdType {
        return switch (command) {
            inline else => |value| value.pane_id,
        };
    }
};

pub const ResourceResult = union(enum) {
    unchanged,
    changed: ResourceState,
    resync_required: PaneIdType,
    shared_mapping_failed: PaneIdType,
};

pub const Outcome = union(enum) {
    unchanged,
    applied: Applied,
    resync_requested: PaneIdType,
    shared_disabled: PaneIdType,
};

pub const EffectEvent = enum {
    apply,
    disable_shared,
    request_snapshot,
};
