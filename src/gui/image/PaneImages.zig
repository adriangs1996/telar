//! The window's Kitty graphics consumer: the textures the renderer holds,
//! the presented machine's placements resolved for drawing, and the uploads
//! and releases the next frame hands to the backend. Procedures live in
//! `pane_images.zig`.
const std = @import("std");
const core = @import("telar-core");
const GpuImages = @import("GpuImages.zig");
const ImagePlacement = @import("ImagePlacement.zig");
const ResolvedFrom = @import("ResolvedFrom.zig");
const native = @import("../native/native.zig");
const ImageDraw = @import("../native/ImageDraw.zig");
const ImageUpload = @import("../native/ImageUpload.zig");
const PaneImages = @This();

/// Placements resolved at once; the frame cannot draw more image quads.
pub const capacity = ImageDraw.capacity;
pub const limit = core.Limit.declare("gui.images.placements_per_frame", "image placements", capacity);
/// Twice `capacity`, a power of two, so probes stay short.
pub const shown_index_len = 2 * capacity;

comptime {
    // `pane_images` wraps its probes with a mask.
    std.debug.assert(std.math.isPowerOfTwo(shown_index_len));
}

pub const ShownImage = @import("ShownImage.zig");

gpu: GpuImages = .{},
placements: [capacity]ImagePlacement = undefined,
/// Each kept placement's source rectangle in its image, until its texture
/// coordinates are resolved.
sources: [capacity]core.RectRect = undefined,
placement_count: usize = 0,
/// The distinct images the resolved placements show, each with the texture
/// it draws; uploads are looked for once per image, not per placement.
shown: [capacity]ShownImage = undefined,
shown_count: usize = 0,
/// Open-addressed index from (pane, image id) to `shown`, rebuilt with it.
shown_index: [shown_index_len]u16 = undefined,
/// Visible placements left out of the last build because the list was full.
dropped: usize = 0,
/// Advances once per prepared frame; rows remember the last one that used them.
frame: u64 = 0,
/// Advances when a texture becomes ready, fails or leaves.
revision: u64 = 1,
built: ?ResolvedFrom = null,
/// The window clock of the current prepare.
now_ns: u64 = 0,
/// What the last upload pass saw: store ingress, texture revision and
/// uploads in flight, and for which machine.
started_from: [3]u64 = @splat(std.math.maxInt(u64)),
started_machine: u8 = 0,
/// Generations drawn for the first time, for telemetry.
presented: u64 = 0,
uploads: [ImageUpload.uploads_in_flight]native.ImageUpload = undefined,
upload_count: u32 = 0,
releases: [GpuImages.capacity]u32 = undefined,
release_count: u32 = 0,

pub fn resolved(self: *const PaneImages) []const ImagePlacement {
    return self.placements[0..self.placement_count];
}
