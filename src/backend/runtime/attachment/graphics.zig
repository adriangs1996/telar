//! Per-client synchronization state for one pane's Kitty graphics projection.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("telar-core");
const pane_mod = @import("../../pane/root.zig");

const Io = std.Io;
const Pane = pane_mod.Pane;

const shm_supported =
    builtin.os.tag != .windows and !builtin.abi.isAndroid() and builtin.link_libc;

pub const shared_memory_supported = shm_supported;

var shared_freeze_sequence = std.atomic.Value(u64).init(0);
var shared_freeze_nonce = std.atomic.Value(u32).init(0);

pub fn initSharedFreezeNonce(io: Io) void {
    var bytes: [4]u8 = undefined;
    io.random(&bytes);
    shared_freeze_nonce.store(@as(u32, @bitCast(bytes)) | 1, .monotonic);
}

pub fn freezeSharedPixels(pixels: []const u8) ?core.graphics.ShmName {
    if (comptime !shm_supported) return null;
    var nonce = shared_freeze_nonce.load(.monotonic);
    if (nonce == 0) {
        nonce = @as(u32, @bitCast(std.c.getpid())) | 1;
        shared_freeze_nonce.store(nonce, .monotonic);
    }
    const sequence = shared_freeze_sequence.fetchAdd(1, .monotonic);
    var text: [core.graphics.max_shm_name_bytes]u8 = undefined;
    const printed = std.fmt.bufPrint(&text, "/tlr{x:0>8}{x}", .{ nonce, sequence }) catch
        return null;
    const name = core.graphics.ShmName.init(printed) catch return null;
    const fd = std.c.shm_open(
        name.sliceZ(),
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true })),
        @as(u16, 0o600),
    );
    if (std.posix.errno(fd) != .SUCCESS) return null;
    defer _ = std.c.close(fd);
    if (std.c.ftruncate(fd, @intCast(pixels.len)) != 0) {
        _ = std.c.shm_unlink(name.sliceZ());
        return null;
    }
    const map = std.posix.mmap(
        null,
        pixels.len,
        .{ .READ = true, .WRITE = true },
        std.c.MAP{ .TYPE = .SHARED },
        fd,
        0,
    ) catch {
        _ = std.c.shm_unlink(name.sliceZ());
        return null;
    };
    defer std.posix.munmap(map);
    @memcpy(map[0..pixels.len], pixels);
    return name;
}

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
