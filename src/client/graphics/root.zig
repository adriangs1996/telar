pub const store = @import("store.zig");
pub const retained = @import("retained.zig");

test {
    _ = @import("tests.zig");
}
pub const ImageIdentity = store.ImageIdentity;
pub const PlacementIdentity = store.PlacementIdentity;
pub const SharedPixels = store.SharedPixels;
pub const PixelAllocation = store.PixelAllocation;
pub const supportsSharedMemory = store.supportsSharedMemory;
pub const identity = store.identity;
pub const ResourceStore = store.ResourceStore;
