const KnownImageType = @import("KnownImage.zig");
const KnownPlacementType = @import("KnownPlacement.zig");
const TransferType = @import("Transfer.zig");
const PaneType = @import("../../pane/Pane.zig");
const graphics = @import("graphics.zig");
const max_image_bytes_per_pane_module = @import("telar-core").max_image_bytes_per_pane;
const TimingType = @import("telar-core").Timing;
const max_images_per_pane_module = @import("telar-core").max_images_per_pane;
const max_placements_per_pane_module = @import("telar-core").max_placements_per_pane;
const std = @import("std");
const Sync = @This();

pub const KnownImage = @import("KnownImage.zig");
pub const KnownPlacement = @import("KnownPlacement.zig");
pub const Transfer = @import("Transfer.zig");

pane: *PaneType,
snapshot: graphics.SnapshotState,
revision: u64 = 1,
target_revision: u64 = 0,
batch_active: bool = false,
observed_revision: u64,
credit: usize = max_image_bytes_per_pane_module,
shared_transport: bool = false,
sent_images: u32 = 0,
sent_placements: u32 = 0,
stage_blocked: u32 = 0,
/// Transfers adopted from the media actor's parked objects: no copy on
/// the runtime thread.
adopted: u32 = 0,
freeze: TimingType = .{},
transfer: ?TransferType = null,
known_images: [max_images_per_pane_module]?KnownImageType =
    [_]?KnownImageType{null} ** max_images_per_pane_module,
known_placements: [max_placements_per_pane_module]?KnownPlacementType =
    [_]?KnownPlacementType{null} ** max_placements_per_pane_module,
gpa: std.mem.Allocator,

pub fn init(gpa: std.mem.Allocator, pane: *PaneType) Sync {
    return .{
        .pane = pane,
        .gpa = gpa,
        .snapshot = if (!pane.graphics_present) .idle else .begin_pending,
        .observed_revision = if (!pane.graphics_present) pane.graphics_revision else 0,
    };
}

pub fn deinit(sync: *Sync) void {
    sync.freeTransfer();
}

pub fn reset(sync: *Sync) void {
    sync.freeTransfer();
    sync.snapshot = .begin_pending;
    sync.batch_active = false;
    sync.target_revision = 0;
    sync.observed_revision = 0;
    sync.known_images = [_]?KnownImageType{null} ** max_images_per_pane_module;
    sync.known_placements = [_]?KnownPlacementType{null} ** max_placements_per_pane_module;
}

pub fn freeTransfer(sync: *Sync) void {
    if (sync.transfer) |transfer| {
        sync.gpa.free(transfer.pixels);
        sync.pane.media_allocator.releaseManual(transfer.reserved_len);
        if (transfer.shared_name) |name| {
            if (!transfer.metadata_sent) {
                _ = std.c.shm_unlink(name.sliceZ());
            }
        }
    }
    sync.transfer = null;
}
