//! Retains bounded runtime images without a GPU image consumer in this slice.
const client = @import("telar-client");
const GenericResourceStore = client.GenericResourceStore;
pub const Store = GenericResourceStore(@This());
pub const State = @import("GraphicsState.zig");
pub const ImageState = State;
pub const PlacementState = State;

pub fn imageCreated(_: *Store) !ImageState {
    return .{};
}
pub fn placementCreated(_: *Store) !PlacementState {
    return .{};
}
pub fn releaseImage(_: *Store, _: *Store.ImageEntry) void {}
pub fn imageDeleted(_: *Store, _: Store.ImageEntry) void {}
pub fn placementDeleted(_: *Store, _: Store.PlacementEntry) void {}
pub fn placementChanged(_: *Store, _: client.PlacementIdentity, _: *Store.PlacementEntry) void {}
pub fn placementVisibility(_: *Store, _: *Store.PlacementEntry, _: bool) void {}
pub fn canRelease(_: *Store, _: client.ImageIdentity, _: *const Store.ImageEntry) bool {
    return true;
}
pub fn deinit(_: *Store) void {}
