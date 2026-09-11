//! Bounded image ingestion, allocation, revisions and retained-resource credits.
//! Delivery owns its extension state and reports when a retired image is free.

const builtin = @import("builtin");
const PaneIdType = @import("telar-core").PaneId;
const ImageKeyType = @import("telar-core").ImageKey;
const ImageIdentity = @import("ImageIdentity.zig");

pub const native = @cImport({
    @cInclude("sys/stat.h");
});

pub fn supportsSharedMemory() bool {
    return builtin.os.tag != .windows and !builtin.abi.isAndroid() and builtin.link_libc;
}

pub fn identity(pane_id: PaneIdType, key: ImageKeyType) ImageIdentity {
    return .{ .pane_id = pane_id, .image_id = key.image_id, .generation = key.generation };
}
