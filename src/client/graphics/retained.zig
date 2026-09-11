//! In-memory delivery policy for consumers that retain pixel slices across turns.
//! Leases must be returned before catalog teardown. No host protocol is involved.

const ImageStateType = @import("ImageState.zig");
const PlacementStateType = @import("PlacementState.zig");
const LeaseType = @import("Lease.zig");
const GenericResourceStore = @import("GenericResourceStore.zig").Type;
const ImageIdentityType = @import("ImageIdentity.zig");
const std = @import("std");
const PlacementIdentityType = @import("PlacementIdentity.zig");

pub const Store = GenericResourceStore(@This());
pub const State = @import("State.zig");
pub const ImageState = @import("ImageState.zig");
pub const PlacementState = @import("PlacementState.zig");
pub const Lease = @import("Lease.zig");

/// Borrows completed pixels until the matching release, without retaining map pointers.
/// Example: `const lease = try retain(&store, identity); defer release(&store, lease);`.
pub fn retain(store: *Store, identity: ImageIdentityType) !LeaseType {
    const image = store.images.getPtr(identity) orelse return error.UnknownGraphicsImage;
    if (image.received != image.pixels.len or image.retire_pending) {
        return error.GraphicsImageUnavailable;
    }

    image.delivery.leases = std.math.add(u32, image.delivery.leases, 1) catch return error.GraphicsLeaseLimit;
    return .{ .identity = identity, .pixels = image.pixels };
}

/// Returns one acquired lease exactly once, then collects obsolete allocations.
/// Example: `release(&store, lease);`.
pub fn release(store: *Store, lease: LeaseType) void {
    const image = store.images.getPtr(lease.identity) orelse unreachable;
    std.debug.assert(image.delivery.leases != 0);
    image.delivery.leases -= 1;
    store.collectRetired(lease.identity.pane_id, lease.identity.image_id);
}

pub fn imageCreated(_: *Store) !ImageStateType {
    return .{};
}
pub fn placementCreated(_: *Store) !PlacementStateType {
    return .{};
}
pub fn releaseImage(_: *Store, image: *Store.ImageEntry) void {
    std.debug.assert(image.delivery.leases == 0);
}
pub fn imageDeleted(_: *Store, _: Store.ImageEntry) void {}
pub fn placementDeleted(_: *Store, _: Store.PlacementEntry) void {}
pub fn placementChanged(_: *Store, _: PlacementIdentityType, _: *Store.PlacementEntry) void {}
pub fn placementVisibility(_: *Store, _: *Store.PlacementEntry, _: bool) void {}
pub fn canRelease(_: *Store, _: ImageIdentityType, image: *const Store.ImageEntry) bool {
    return image.delivery.leases == 0;
}
pub fn deinit(_: *Store) void {}
