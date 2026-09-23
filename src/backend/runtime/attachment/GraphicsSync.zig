const core = @import("telar-core");
const Pane = @import("../../pane/Pane.zig");
const graphics = @import("graphics.zig");
const std = @import("std");
const Sync = @This();

pub const KnownImage = @import("KnownImage.zig");
pub const KnownPlacement = @import("KnownPlacement.zig");
pub const Transfer = @import("Transfer.zig");

pane: *Pane,
snapshot: graphics.SnapshotState,
revision: u64 = 1,
target_revision: u64 = 0,
batch_active: bool = false,
observed_revision: u64,
credit: usize = core.max_image_bytes_per_pane,
shared_transport: bool = false,
sent_images: u32 = 0,
sent_placements: u32 = 0,
stage_blocked: u32 = 0,
/// Transfers adopted from the media actor's parked objects: no copy on
/// the runtime thread.
adopted: u32 = 0,
freeze: core.Timing = .{},
transfer: ?Transfer = null,
known_images: [core.max_images_per_pane]?KnownImage =
    [_]?KnownImage{null} ** core.max_images_per_pane,
known_placements: [core.max_placements_per_pane]?KnownPlacement =
    [_]?KnownPlacement{null} ** core.max_placements_per_pane,
gpa: std.mem.Allocator,

pub fn init(gpa: std.mem.Allocator, pane: *Pane) Sync {
    return .{
        .pane = pane,
        .gpa = gpa,
        .snapshot = if (!pane.graphics_present) .idle else .begin_pending,
        .observed_revision = if (!pane.graphics_present) pane.graphics_revision else 0,
    };
}

pub fn deinit(self: *Sync) void {
    self.freeTransfer();
}

pub fn reset(self: *Sync) void {
    self.freeTransfer();
    self.snapshot = .begin_pending;
    self.batch_active = false;
    self.target_revision = 0;
    self.observed_revision = 0;
    self.known_images = [_]?KnownImage{null} ** core.max_images_per_pane;
    self.known_placements = [_]?KnownPlacement{null} ** core.max_placements_per_pane;
}

pub fn freeTransfer(self: *Sync) void {
    if (self.transfer) |transfer| {
        self.gpa.free(transfer.pixels);
        self.pane.media_allocator.releaseManual(transfer.reserved_len);
        if (transfer.shared_name) |name| {
            if (!transfer.metadata_sent) {
                _ = std.c.shm_unlink(name.sliceZ());
            }
        }
    }
    self.transfer = null;
}
