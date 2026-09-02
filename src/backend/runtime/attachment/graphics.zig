//! Per-client synchronization state for one pane's Kitty graphics projection.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../../pane/root.zig");

const Pane = pane_mod.Pane;

const shared_transfer = pane_mod.shared_transfer;

pub const shared_memory_supported = shared_transfer.shared_memory_supported;
pub const initSharedFreezeNonce = shared_transfer.initSharedFreezeNonce;
pub const freezeSharedPixels = shared_transfer.freezeSharedPixels;

pub const SnapshotState = enum { begin_pending, open, idle };

pub const Sync = struct {
    pub const KnownImage = struct { key: core.graphics.ImageKey };
    pub const KnownPlacement = struct { placement: core.graphics.Placement };
    pub const Transfer = struct {
        metadata: core.graphics.Image,
        pixels: []u8,
        shared_name: ?core.graphics.ShmName = null,
        reserved_len: usize = 0,
        placements: [core.graphics.max_placements_per_pane]core.graphics.Placement = undefined,
        placement_count: usize = 0,
        placement_index: usize = 0,
        offset: usize = 0,
        metadata_sent: bool = false,
    };

    pane: *Pane,
    snapshot: SnapshotState,
    revision: u64 = 1,
    target_revision: u64 = 0,
    batch_active: bool = false,
    observed_revision: u64,
    credit: usize = core.graphics.max_image_bytes_per_pane,
    shared_transport: bool = false,
    sent_images: u32 = 0,
    sent_placements: u32 = 0,
    stage_blocked: u32 = 0,
    /// Transfers adopted from the media actor's parked objects: no copy on
    /// the runtime thread.
    adopted: u32 = 0,
    freeze: core.diagnostics.Timing = .{},
    transfer: ?Transfer = null,
    known_images: [core.graphics.max_images_per_pane]?KnownImage =
        [_]?KnownImage{null} ** core.graphics.max_images_per_pane,
    known_placements: [core.graphics.max_placements_per_pane]?KnownPlacement =
        [_]?KnownPlacement{null} ** core.graphics.max_placements_per_pane,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, pane: *Pane) Sync {
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
        sync.known_images = [_]?KnownImage{null} ** core.graphics.max_images_per_pane;
        sync.known_placements = [_]?KnownPlacement{null} ** core.graphics.max_placements_per_pane;
    }

    pub fn freeTransfer(sync: *Sync) void {
        if (sync.transfer) |transfer| {
            sync.gpa.free(transfer.pixels);
            sync.pane.media_allocator.releaseManual(transfer.reserved_len);
            if (transfer.shared_name) |name| if (!transfer.metadata_sent) {
                _ = std.c.shm_unlink(name.sliceZ());
            };
        }
        sync.transfer = null;
    }
};
