//! Bounded image ingestion, allocation, revisions and retained-resource credits.
//! Delivery owns its extension state and reports when a retired image is free.

const core = @import("telar-core");
const builtin = @import("builtin");
const ImageIdentity = @import("ImageIdentity.zig");

pub fn supportsSharedMemory() bool {
    return builtin.os.tag != .windows and !builtin.abi.isAndroid() and builtin.link_libc;
}

pub fn identity(pane_id: core.PaneId, key: core.ImageKey) ImageIdentity {
    return .{ .pane_id = pane_id, .image_id = key.image_id, .generation = key.generation };
}
