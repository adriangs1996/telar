//! The window's Kitty graphics consumer: the textures the renderer holds,
//! the presented machine's placements resolved for drawing, and the uploads
//! and releases the next frame hands to the backend. Procedures live in
//! `pane_images.zig`.
const GpuImages = @import("GpuImages.zig");
const ImagePlacement = @import("ImagePlacement.zig");
const ResolvedFrom = @import("ResolvedFrom.zig");
const native = @import("../native/native.zig");
const ImageDraw = @import("../native/ImageDraw.zig");
const ImageUpload = @import("../native/ImageUpload.zig");
const PaneImages = @This();

/// Placements resolved at once; the frame cannot draw more image quads.
pub const capacity = ImageDraw.capacity;

gpu: GpuImages = .{},
placements: [capacity]ImagePlacement = undefined,
placement_count: usize = 0,
/// Visible placements left out of the last build because the list was full.
dropped: usize = 0,
/// Advances once per prepared frame; rows remember the last one that used them.
frame: u64 = 0,
/// Advances when a texture becomes ready, fails or leaves.
revision: u64 = 1,
built: ?ResolvedFrom = null,
uploads: [ImageUpload.uploads_in_flight]native.ImageUpload = undefined,
upload_count: u32 = 0,
releases: [GpuImages.capacity]u32 = undefined,
release_count: u32 = 0,

pub fn resolved(self: *const PaneImages) []const ImagePlacement {
    return self.placements[0..self.placement_count];
}
