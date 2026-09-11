//! Bounded image ingestion, allocation, revisions and retained-resource credits.
//! Delivery owns its extension state and reports when a retired image is free.
const std = @import("std");
const builtin = @import("builtin");
pub const native = @cImport({
    @cInclude("sys/stat.h");
});
const core = @import("telar-core");
pub const schema = core.schema;
pub const graphics = core.graphics;

pub const ImageIdentity = @import("ImageIdentity.zig");

pub const PlacementIdentity = @import("PlacementIdentity.zig");

pub const SharedPixels = @import("SharedPixels.zig");

pub const PixelAllocation = @import("PixelAllocation.zig");

pub fn supportsSharedMemory() bool {
    return builtin.os.tag != .windows and !builtin.abi.isAndroid() and builtin.link_libc;
}

pub fn identity(pane_id: schema.PaneId, key: graphics.ImageKey) ImageIdentity {
    return .{ .pane_id = pane_id, .image_id = key.image_id, .generation = key.generation };
}

pub const ResourceStore = @import("GenericResourceStore.zig").Type;
