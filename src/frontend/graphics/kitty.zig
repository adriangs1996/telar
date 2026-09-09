//! Client-side Kitty graphics resource storage and host-protocol emission.

const std = @import("std");
const native = @cImport({
    @cInclude("sys/stat.h");
});
const codec = @import("kitty_codec.zig");
const sidebar = @import("kitty_sidebar.zig");
pub const transmission_budget_per_frame = codec.transmission_budget_per_frame;
pub const OutputPlacement = codec.OutputPlacement;
pub const ChunkProgress = codec.ChunkProgress;
pub const TransmissionChunks = codec.TransmissionChunks;
pub const PngTransmissionChunks = codec.PngTransmissionChunks;
pub const Transmission = codec.Transmission;
pub const SharedTransmission = codec.SharedTransmission;
pub const writeTransmissionChunks = codec.writeTransmissionChunks;
pub const writePngTransmissionChunks = codec.writePngTransmissionChunks;
pub const writeTransmission = codec.writeTransmission;
pub const writeSharedTransmission = codec.writeSharedTransmission;
pub const writeTransmissionAbort = codec.writeTransmissionAbort;
pub const PlacementCommand = codec.PlacementCommand;
pub const writePlacement = codec.writePlacement;
pub const writeUiPlacement = codec.writeUiPlacement;
pub const writeDeleteImage = codec.writeDeleteImage;
pub const writeDeletePlacement = codec.writeDeletePlacement;
pub const writeDeleteImageRange = codec.writeDeleteImageRange;
pub const SidebarProvider = sidebar.SidebarProvider;
pub const SidebarProviderPlacement = sidebar.SidebarProviderPlacement;
pub const SidebarFocus = sidebar.SidebarFocus;
pub const SidebarContent = sidebar.SidebarContent;
pub const CellSize = sidebar.CellSize;
pub const KittySidebarRenderer = sidebar.KittySidebarRenderer;

const builtin = @import("builtin");
const core = @import("telar-core");
const workspace = @import("../workspace/root.zig");
const layout = workspace.layout;
const multiplexer = workspace.multiplexer;
const capability_mod = @import("capabilities.zig");

const Io = std.Io;
const diagnostics = core.diagnostics;
const schema = core.schema;
const graphics = core.graphics;

pub fn supportsSharedMemory() bool {
    return builtin.os.tag != .windows and !builtin.abi.isAndroid() and builtin.link_libc;
}

/// Whether this client build can map POSIX shared memory the runtime names.
/// The client declares it to the runtime explicitly; nothing is assumed.
pub fn clientSupportsSharedMemory() bool {
    return supportsSharedMemory();
}

pub const query_image_id = capability_mod.query_image_id;
pub const zlib_query_image_id = capability_mod.zlib_query_image_id;
pub const capability_timeout_ns = capability_mod.timeout_ns;
pub const capability_query = capability_mod.query;
pub const Support = capability_mod.Support;
pub const SidebarRendering = capability_mod.SidebarRendering;
pub const ResolvedSidebarRendering = capability_mod.ResolvedSidebarRendering;

pub const Configuration = struct {
    support: Support,
    cell_width: u16,
    cell_height: u16,
};

/// Encoded image bytes one media pass may put on the direct-data fallback
/// wire. Local Ghostty sessions use a compact shared-memory command instead.
/// Raw pixel bytes one frame may push through the zlib deflater before an
/// inline transmission. Bounds the writer's compression work per pass to
/// about two milliseconds at the ~300 MiB/s a `.fastest` deflate measures.
pub const compression_slice_per_frame: usize = 512 * 1024;
/// Below this raw size the o=z probe, header, and deflate overhead outweigh
/// the saved wire bytes.
const compression_min_bytes: usize = 8 * 1024;

const ImageIdentity = struct {
    pane_id: schema.PaneId,
    image_id: u32,
    generation: u64,
};

const PlacementIdentity = struct {
    pane_id: schema.PaneId,
    virtual_id: u64,
};

const SharedPixels = struct {
    name: [64]u8 = undefined,
    len: u8,

    fn slice(shared: *const SharedPixels) []const u8 {
        return shared.name[0..shared.len];
    }

    fn sliceZ(shared: *const SharedPixels) [:0]const u8 {
        return shared.name[0..shared.len :0];
    }
};

const PixelAllocation = struct {
    pixels: []u8,
    shared: ?SharedPixels = null,
};

/// In-progress deflate of one image's pixels. Heap-allocated and never moved,
/// because the compressor holds pointers into the allocating writer and the
/// window buffer.
pub const Compression = struct {
    input: []u8 = &.{},
    input_len: usize = 0,
    finish_after: bool = false,
    failed: bool = false,
    allocating: Io.Writer.Allocating,
    window: [std.compress.flate.max_window_len]u8,
    compress: std.compress.flate.Compress,
    offset: usize,

    /// Compresses only copied input; no store, image or mutable model is borrowed.
    /// Example: `const completed = Compression.run(job);`.
    pub fn run(job: *Compression) *Compression {
        job.compress.writer.writeAll(job.input[0..job.input_len]) catch {
            job.failed = true;
            return job;
        };
        if (job.finish_after) {
            job.compress.finish() catch {
                job.failed = true;
            };
        }

        return job;
    }
};

pub const CompressionScheduler = struct {
    context: *anyopaque,
    start: *const fn (*anyopaque, *Compression) anyerror!void,
};

const ImageEntry = struct {
    metadata: graphics.Image,
    pixels: []u8,
    shared: ?SharedPixels = null,
    received: usize = 0,
    chunks: usize = 0,
    external_id: u32,
    transmitted: bool = false,
    retire_pending: bool = false,
    force_direct: bool = false,
    /// Finished zlib stream of `pixels`, freed once the transmission closes.
    compressed: ?[]u8 = null,
    compression: ?*Compression = null,
    /// Deflate did not pay for itself (or failed); ship raw and never retry.
    incompressible: bool = false,
    /// The host terminal was handed the shared object's name. Only then does
    /// retirement wait for the host to consume and unlink it.
    emitted_shared: bool = false,
    /// Writer pass that emitted the shared name, for the consume deadline.
    transmitted_pass: u64 = 0,
    /// Writer clock when the shared name was emitted; zero outside Debug.
    transmitted_ns: u64 = 0,
    /// The host answered `OK` for the shared transmission: it copied the
    /// object, so retirement needs no probe.
    host_acked: bool = false,
};

/// Writer passes a host may sit on a shared name before the client reclaims
/// the object and falls back to inline transmission. Roughly three seconds
/// at the 60Hz pace: far beyond a healthy Ghostty, short enough that a host
/// that ignored the name cannot pin pane memory credit forever.
const shared_consume_deadline_passes: u64 = 180;
/// Consecutive expiries after which the host is deemed unable to consume
/// shared names at all and every image goes back to inline transmission.
const shared_expiry_disable_threshold: u8 = 2;

const PlacementEntry = struct {
    placement: graphics.Placement,
    external_id: u32,
    emitted_image_id: ?u32 = null,
    dirty: bool = true,
};

const Delete = union(enum) {
    image: u32,
    placement: struct { image_id: u32, placement_id: u32 },
};

const FallbackPlacement = struct {
    placement: graphics.Placement,
    external_id: u32,
};

const PartialPlacement = struct {
    pane_id: schema.PaneId,
    placement: graphics.Placement,
    external_id: u32,
};

/// A chunked transfer the frame budget interrupted. The next frame resumes
/// it before emitting any other graphics escape, which the protocol demands.
const PartialTransmission = struct {
    key: ImageIdentity,
    external_id: u32,
    offset: usize,
    /// The open transfer streams the entry's compressed bytes, so a resume
    /// must keep reading the same buffer the header's `o=z` promised.
    compressed: bool = false,
    fallback_count: usize = 0,
    fallbacks: [graphics.max_placements_per_pane]FallbackPlacement = undefined,
};

const FallbackFrame = struct {
    partial: PartialTransmission,
    image: ImageEntry,
};

const PlacementGeometry = struct {
    pane_id: schema.PaneId,
    placement: graphics.Placement,
    image: graphics.Image,
};

pub const Store = struct {
    pub const Credit = struct { pane_id: schema.PaneId, bytes: usize };
    const PaneUsage = struct {
        count: usize = 0,
        bytes: usize = 0,
        placements: usize = 0,
        released_bytes: usize = 0,
    };
    const RevisionState = struct {
        latest: u64 = 0,
        snapshot: ?u64 = null,
        awaiting_snapshot: bool = false,
    };
    gpa: std.mem.Allocator,
    images: std.AutoHashMapUnmanaged(ImageIdentity, ImageEntry) = .{},
    placements: std.AutoHashMapUnmanaged(PlacementIdentity, PlacementEntry) = .{},
    /// Images marked `retire_pending` and not yet removed; the sweep that
    /// retires them runs only while this is non-zero.
    retire_candidates: u32 = 0,
    delete_queue: [graphics.max_placements_per_pane * 2]Delete = undefined,
    delete_head: usize = 0,
    delete_len: usize = 0,
    delete_overflow: bool = false,
    total_bytes: usize = 0,
    next_image_id: u32 = 1,
    next_placement_id: u32 = 1,
    next_shm_id: u64 = 1,
    shared_memory: bool = false,
    /// The host answered the `o=z` capability probe, so inline transmissions
    /// may ship a zlib stream instead of raw pixels.
    host_zlib: bool = false,
    compression_scheduler: ?CompressionScheduler = null,
    pending_compression: ?*Compression = null,
    orphan_compression: bool = false,
    compression_input: []u8 = &.{},
    /// Incremented once per writer pass; shared-name emissions stamp it so
    /// the consume deadline needs no clock.
    pass_counter: u64 = 0,
    shared_expiries: u8 = 0,
    /// Monotonic clock stamped by the writer at each pass. Retirement is
    /// observed on writer passes, so this is the clock retire latency uses.
    clock_ns: u64 = 0,
    /// Emission of a shared name to the host until the host's unlink was
    /// observed. Measured at writer-pass granularity.
    retire_latency: diagnostics.Timing = .{},
    damage: bool = false,
    ingress_revision: u64 = 0,
    partial: ?PartialTransmission = null,
    // Maps rather than `[max_panes_per_tab]` arrays: one store serves every
    // tab of the client, so its pane bound is tabs times panes, not one tab.
    revisions: std.AutoHashMapUnmanaged(schema.PaneId, RevisionState) = .{},
    hidden_panes: std.AutoHashMapUnmanaged(schema.PaneId, void) = .{},
    // Maintained on every insert and remove, so quota checks and visibility
    // queries cost one lookup instead of a scan of every image in the client.
    usage: std.AutoHashMapUnmanaged(schema.PaneId, PaneUsage) = .{},

    fn beginPresentation(store: *Store, now_ns: u64) void {
        store.pass_counter +%= 1;
        store.clock_ns = now_ns;
        store.expireSharedTransmissions();
    }

    fn completeTransmission(store: *Store, image: *ImageEntry, transport: enum { inline_data, shared_memory }) void {
        image.transmitted = true;
        switch (transport) {
            .inline_data => {
                store.freeCompression(image);
                store.partial = null;
            },
            .shared_memory => {
                image.emitted_shared = true;
                image.transmitted_pass = store.pass_counter;
                image.transmitted_ns = store.clock_ns;
            },
        }
    }

    fn recoverDeleteOverflow(store: *Store) void {
        store.delete_head = 0;
        store.delete_len = 0;
        store.delete_overflow = false;
        var reset_images = store.images.iterator();
        while (reset_images.next()) |entry| {
            entry.value_ptr.transmitted = false;
            entry.value_ptr.force_direct = true;
        }
        var reset_placements = store.placements.iterator();
        while (reset_placements.next()) |entry| {
            entry.value_ptr.emitted_image_id = null;
            entry.value_ptr.dirty = true;
        }
        store.collectRetired(null, null);
    }

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn initSharedMemory(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa, .shared_memory = supportsSharedMemory() };
    }

    pub fn deinit(store: *Store) void {
        // The client joins its compression actor before destroying the store.
        if (store.pending_compression) |job| {
            store.completeCompression(job);
        }

        var images = store.images.iterator();
        while (images.next()) |entry| store.freePixels(entry.value_ptr);
        store.gpa.free(store.compression_input);
        store.images.deinit(store.gpa);
        store.placements.deinit(store.gpa);
        store.revisions.deinit(store.gpa);
        store.hidden_panes.deinit(store.gpa);
        store.usage.deinit(store.gpa);
    }

    /// Returns the physical-resource revision observed by the client
    /// presenter. Only accepted runtime graphics messages advance it.
    ///
    /// ```zig
    /// const before = store.ingressVersion();
    /// ```
    pub fn ingressVersion(store: *const Store) u64 {
        return store.ingress_revision;
    }

    fn allocatePixels(store: *Store, byte_len: usize) !PixelAllocation {
        if (store.shared_memory) {
            if (store.allocateSharedPixels(byte_len)) |allocation| {
                return allocation;
            } else |_| {}
        }
        return .{ .pixels = try store.gpa.alloc(u8, byte_len) };
    }

    fn allocateSharedPixels(store: *Store, byte_len: usize) !PixelAllocation {
        if (comptime !supportsSharedMemory()) {
            return error.SharedMemoryUnavailable;
        }

        var attempts: u8 = 0;
        while (attempts < 8) : (attempts += 1) {
            const sequence = store.next_shm_id;
            store.next_shm_id +%= 1;
            if (store.next_shm_id == 0) {
                store.next_shm_id = 1;
            }
            var shared: SharedPixels = .{ .len = 0 };
            const name = std.fmt.bufPrintZ(
                &shared.name,
                "/telar-{d}-{x}",
                .{ std.c.getpid(), sequence },
            ) catch return error.SharedMemoryUnavailable;
            shared.len = @intCast(name.len);
            const fd = std.c.shm_open(
                name,
                @as(c_int, @bitCast(std.c.O{
                    .ACCMODE = .RDWR,
                    .CREAT = true,
                    .EXCL = true,
                })),
                @as(u16, 0o600),
            );
            switch (std.posix.errno(fd)) {
                .SUCCESS => {},
                .EXIST => continue,
                else => return error.SharedMemoryUnavailable,
            }
            defer _ = std.c.close(fd);
            errdefer _ = std.c.shm_unlink(name);
            if (std.c.ftruncate(fd, @intCast(byte_len)) != 0) {
                return error.SharedMemoryUnavailable;
            }
            const map = std.posix.mmap(
                null,
                byte_len,
                .{ .READ = true, .WRITE = true },
                std.c.MAP{ .TYPE = .SHARED },
                fd,
                0,
            ) catch return error.SharedMemoryUnavailable;
            return .{ .pixels = map, .shared = shared };
        }
        return error.SharedMemoryUnavailable;
    }

    fn freeAllocation(store: *Store, allocation: *PixelAllocation) void {
        if (allocation.pixels.len == 0) {
            return;
        }
        var entry: ImageEntry = .{
            .metadata = undefined,
            .pixels = allocation.pixels,
            .shared = allocation.shared,
            .external_id = 0,
        };
        store.freePixels(&entry);
        allocation.pixels = &.{};
        allocation.shared = null;
    }

    fn freePixels(store: *Store, entry: *ImageEntry) void {
        store.freeCompression(entry);
        if (entry.shared) |*shared| {
            if (comptime supportsSharedMemory()) {
                _ = std.c.shm_unlink(shared.sliceZ());
                std.posix.munmap(@alignCast(entry.pixels));
            }
        } else {
            store.gpa.free(entry.pixels);
        }
        entry.pixels = &.{};
        entry.shared = null;
    }

    fn freeCompression(store: *Store, entry: *ImageEntry) void {
        if (entry.compression) |state| {
            if (store.pending_compression == state) {
                store.orphan_compression = true;
            } else {
                state.allocating.deinit();
                store.gpa.destroy(state);
            }

            entry.compression = null;
        }
        if (entry.compressed) |bytes| {
            store.gpa.free(bytes);
            entry.compressed = null;
        }
    }

    /// Ends the worker borrow before publishing compression readiness.
    /// Example: `store.completeCompression(job);`.
    pub fn completeCompression(store: *Store, job: *Compression) void {
        std.debug.assert(store.pending_compression == job);
        store.pending_compression = null;
        if (store.orphan_compression) {
            job.allocating.deinit();
            store.gpa.destroy(job);
            store.orphan_compression = false;
        }

        store.damage = true;
    }

    /// Advances one image's deflate by at most `budget` raw bytes. Returns
    /// true once a transmission source exists: the finished zlib stream, or
    /// the raw pixels when the host lacks o=z, the image is too small, or
    /// the deflate did not pay for itself. The compressed copy is transient
    /// working memory outside the pane quota: it is bounded by the raw size
    /// it must undercut and freed as soon as the transmission closes.
    fn advanceCompression(store: *Store, entry: *ImageEntry, budget: *usize) bool {
        if (entry.compressed != null or entry.incompressible) {
            return true;
        }
        if (!store.host_zlib or entry.pixels.len < compression_min_bytes) {
            return true;
        }
        if (budget.* == 0) {
            return false;
        }
        if (store.pending_compression != null) {
            return false;
        }

        const state = entry.compression orelse create: {
            const state = store.gpa.create(Compression) catch {
                entry.incompressible = true;
                return true;
            };
            // The compressor asserts a non-empty output buffer at init; the
            // allocating writer grows it past this seed as the stream needs.
            state.allocating = Io.Writer.Allocating.initCapacity(store.gpa, 4096) catch {
                store.gpa.destroy(state);
                entry.incompressible = true;
                return true;
            };
            state.offset = 0;
            state.input = &.{};
            state.input_len = 0;
            state.finish_after = false;
            state.failed = false;
            state.compress = std.compress.flate.Compress.init(
                &state.allocating.writer,
                &state.window,
                .zlib,
                .fastest,
            ) catch {
                state.allocating.deinit();
                store.gpa.destroy(state);
                entry.incompressible = true;
                return true;
            };
            entry.compression = state;
            break :create state;
        };
        if (store.compression_scheduler) |scheduler| {
            if (state.failed) {
                store.freeCompression(entry);
                entry.incompressible = true;
                return true;
            }
            if (state.offset < entry.pixels.len) {
                if (store.compression_input.len == 0) {
                    store.compression_input = store.gpa.alloc(u8, compression_slice_per_frame) catch {
                        store.freeCompression(entry);
                        entry.incompressible = true;
                        return true;
                    };
                }

                state.input = store.compression_input;
                const take = @min(budget.*, @min(state.input.len, entry.pixels.len - state.offset));
                @memcpy(state.input[0..take], entry.pixels[state.offset..][0..take]);
                state.input_len = take;
                state.offset += take;
                state.finish_after = state.offset == entry.pixels.len;
                budget.* -= take;
                store.pending_compression = state;
                scheduler.start(scheduler.context, state) catch {
                    store.pending_compression = null;
                    store.freeCompression(entry);
                    entry.incompressible = true;
                    return true;
                };

                return false;
            }
        } else {
            const take = @min(budget.*, entry.pixels.len - state.offset);
            state.compress.writer.writeAll(entry.pixels[state.offset..][0..take]) catch {
                store.freeCompression(entry);
                entry.incompressible = true;
                return true;
            };
            state.offset += take;
            budget.* -= take;
            if (state.offset < entry.pixels.len) {
                return false;
            }

            state.compress.finish() catch {
                store.freeCompression(entry);
                entry.incompressible = true;
                return true;
            };
        }
        const compressed = state.allocating.toOwnedSlice() catch {
            store.freeCompression(entry);
            entry.incompressible = true;
            return true;
        };
        state.allocating.deinit();
        store.gpa.destroy(state);
        entry.compression = null;
        // The saved wire bytes must justify the host's inflate work.
        if (compressed.len >= entry.pixels.len - entry.pixels.len / 8) {
            store.gpa.free(compressed);
            entry.incompressible = true;
        } else {
            entry.compressed = compressed;
        }
        return true;
    }

    fn sharedPixelsConsumed(_: *Store, entry: *const ImageEntry) bool {
        const shared = entry.shared orelse return true;
        if (!entry.emitted_shared) {
            return true;
        }
        if (entry.host_acked) {
            return true;
        }
        if (comptime !supportsSharedMemory()) {
            return false;
        }
        const fd = std.c.shm_open(
            shared.sliceZ(),
            @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })),
            @as(u16, 0),
        );
        return switch (std.posix.errno(fd)) {
            .SUCCESS => consumed: {
                _ = std.c.close(fd);
                break :consumed false;
            },
            .NOENT => true,
            else => false,
        };
    }

    /// Reclaims shared objects a host never consumed. Without this deadline
    /// one dropped `t=s` command would pin its pane's memory credit forever,
    /// silently under q=2. Expired images retransmit inline from the still
    /// valid mapping, and a host that keeps ignoring names loses them for
    /// the rest of the session.
    fn expireSharedTransmissions(store: *Store) void {
        if (comptime !supportsSharedMemory()) {
            return;
        }
        var images = store.images.iterator();
        while (images.next()) |entry| {
            const image = entry.value_ptr;
            if (image.shared == null or !image.emitted_shared) {
                continue;
            }
            if (store.pass_counter -% image.transmitted_pass < shared_consume_deadline_passes) {
                continue;
            }
            if (store.sharedPixelsConsumed(image)) {
                continue;
            }
            store.loseSharedName(entry.key_ptr.pane_id, image);
            store.shared_expiries +|= 1;
            if (store.shared_expiries >= shared_expiry_disable_threshold) {
                store.shared_memory = false;
            }
        }
    }

    /// The host did not take the object behind a shared name: reclaim it and
    /// send the pixels inline, placements included.
    fn loseSharedName(store: *Store, pane_id: schema.PaneId, image: *ImageEntry) void {
        const shared = if (image.shared) |*value| value else return;
        _ = std.c.shm_unlink(shared.sliceZ());
        image.emitted_shared = false;
        image.host_acked = false;
        image.force_direct = true;
        image.transmitted = false;
        // The host dropped the image with the name, so its placements must
        // follow the inline retransmission.
        var placements = store.placements.iterator();
        while (placements.next()) |placement_entry| {
            if (placement_entry.key_ptr.pane_id != pane_id) {
                continue;
            }
            if (!std.meta.eql(placement_entry.value_ptr.placement.key, image.metadata.key)) {
                continue;
            }
            placement_entry.value_ptr.emitted_image_id = null;
            placement_entry.value_ptr.dirty = true;
        }
        store.damage = true;
    }

    /// Applies the host's reply to a shared transmission by exterior image id.
    /// `OK` marks the object consumed, so a replaced generation retires at
    /// once instead of waiting for a probe; an error reclaims the name and
    /// retransmits inline. Returns whether any image was affected.
    ///
    /// ```zig
    /// if (store.noteHostReply(reply.image_id, reply.supported)) flushCredits();
    /// ```
    pub fn noteHostReply(store: *Store, external_id: u32, ok: bool) bool {
        var images = store.images.iterator();
        while (images.next()) |entry| {
            const image = entry.value_ptr;
            if (image.external_id != external_id or !image.emitted_shared) {
                continue;
            }
            if (ok) {
                image.host_acked = true;
                store.collectRetired(entry.key_ptr.pane_id, entry.key_ptr.image_id);
            } else {
                store.loseSharedName(entry.key_ptr.pane_id, image);
            }
            store.noteIngressChange();
            return true;
        }
        return false;
    }

    fn hasPendingSharedRelease(store: *Store) bool {
        var images = store.images.iterator();
        while (images.next()) |entry| {
            if (!entry.value_ptr.retire_pending or
                store.exteriorGenerationLive(entry.key_ptr.*, entry.value_ptr.external_id))
            {
                continue;
            }
            if (!store.sharedPixelsConsumed(entry.value_ptr)) {
                return true;
            }
        }
        return false;
    }

    pub fn applySnapshot(store: *Store, message: schema.graphics.Snapshot) !void {
        const revision = try store.revisionState(message.pane_id);
        switch (message.phase) {
            .begin => {
                store.clearPaneData(message.pane_id, true);
                revision.latest = message.revision;
                revision.snapshot = message.revision;
                revision.awaiting_snapshot = false;
            },
            .end => {
                if (revision.snapshot != message.revision) {
                    revision.awaiting_snapshot = true;
                    revision.snapshot = null;
                    return error.GraphicsResyncRequired;
                }
                store.removeIncomplete(message.pane_id);
                revision.latest = message.revision;
                revision.snapshot = null;
            },
        }

        store.noteIngressChange();
    }

    pub fn applyImage(store: *Store, message: schema.graphics.Image) !void {
        if (!try store.acceptRevision(message.pane_id, message.revision)) {
            return;
        }
        const byte_len = try store.admitImage(message.pane_id, message.image);
        var allocation = try store.allocatePixels(byte_len);
        errdefer store.freeAllocation(&allocation);
        try store.commitImage(.{ .pane_id = message.pane_id, .image = message.image, .allocation = &allocation, .received = 0 });
        store.noteIngressChange();
    }

    /// A complete image whose pixels the runtime already froze into a shared
    /// memory object it named. The client maps the object read-only: the
    /// pixels never cross the socket and no copy is made. The mapping serves
    /// both the compact `t=s` hand-off to the host and the inline fallback,
    /// and survives the unlink whoever consumes the object performs.
    pub fn applySharedImage(store: *Store, message: schema.graphics.SharedImage) !void {
        if (comptime !supportsSharedMemory()) {
            return error.GraphicsSharedMappingFailed;
        }
        if (!try store.acceptRevision(message.pane_id, message.revision)) {
            return;
        }
        const byte_len = try store.admitImage(message.pane_id, message.image);
        var allocation = store.mapSharedPixels(message.name, byte_len) catch {
            // Nothing references the object if the map fails, so reclaim it
            // here; unlinking twice is harmless because names are unique.
            _ = std.c.shm_unlink(message.name.sliceZ());
            return error.GraphicsSharedMappingFailed;
        };
        errdefer store.freeAllocation(&allocation);
        try store.commitImage(.{ .pane_id = message.pane_id, .image = message.image, .allocation = &allocation, .received = byte_len });
        store.removeOtherGenerations(message.pane_id, message.image.key);
        store.noteIngressChange();
    }

    fn mapSharedPixels(store: *Store, name: graphics.ShmName, byte_len: usize) !PixelAllocation {
        _ = store;
        if (comptime !supportsSharedMemory()) {
            return error.SharedMemoryUnavailable;
        }
        const fd = std.c.shm_open(
            name.sliceZ(),
            @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })),
            @as(u16, 0),
        );
        if (std.posix.errno(fd) != .SUCCESS) {
            return error.SharedMemoryUnavailable;
        }
        defer _ = std.c.close(fd);
        var stat: native.struct_stat = undefined;
        if (native.fstat(fd, &stat) != 0) {
            return error.SharedMemoryUnavailable;
        }

        if (stat.st_size < 0 or @as(u64, @intCast(stat.st_size)) < byte_len) {
            return error.SharedMemoryUnavailable;
        }
        const map = std.posix.mmap(
            null,
            byte_len,
            .{ .READ = true },
            std.c.MAP{ .TYPE = .SHARED },
            fd,
            0,
        ) catch return error.SharedMemoryUnavailable;
        var shared: SharedPixels = .{ .len = 0 };
        @memcpy(shared.name[0 .. name.len + 1], name.bytes[0 .. name.len + 1]);
        shared.len = name.len;
        return .{ .pixels = map, .shared = shared };
    }

    /// Validates one incoming image against every quota and evicts what it
    /// supersedes. Returns the pixel length the caller must provide.
    fn admitImage(store: *Store, pane_id: schema.PaneId, image: graphics.Image) !usize {
        const byte_len = try image.validate(graphics.max_image_bytes_per_pane);
        const key = identity(pane_id, image.key);
        // A new header supersedes every transfer of this image id that never
        // finished, so evict those before quota accounting rather than let a
        // retransmission flood count against the pane.
        store.evictReplacedGenerations(pane_id, image.key);
        const previous = store.images.get(key);
        const pane_usage: PaneUsage = store.usage.get(pane_id) orelse .{};
        const logical_count = store.paneLogicalImageCount(pane_id, image.key.image_id);
        const replacing = store.hasImageId(pane_id, image.key.image_id);
        if (previous == null and !replacing and logical_count >= graphics.max_images_per_pane) {
            return error.GraphicsImageLimitExceeded;
        }
        const previous_len = if (previous) |entry| entry.pixels.len else 0;
        const next_pane_bytes = std.math.add(
            usize,
            pane_usage.bytes - previous_len,
            byte_len,
        ) catch return error.GraphicsQuotaExceeded;
        if (next_pane_bytes > graphics.max_image_bytes_per_pane) {
            return error.GraphicsQuotaExceeded;
        }
        const next_total = std.math.add(
            usize,
            store.total_bytes - previous_len,
            byte_len,
        ) catch return error.GraphicsQuotaExceeded;
        if (next_total > graphics.max_image_bytes_global) {
            return error.GraphicsQuotaExceeded;
        }

        if (store.images.fetchRemove(key)) |removed| {
            store.total_bytes -= removed.value.pixels.len;
            store.noteImageRemoved(pane_id, removed.value.pixels.len);
            var removed_entry = removed.value;
            store.freePixels(&removed_entry);
            store.queueDelete(.{ .image = removed.value.external_id });
        }
        return byte_len;
    }

    const ImageCommit = struct {
        pane_id: schema.PaneId,
        image: graphics.Image,
        allocation: *PixelAllocation,
        received: usize,
    };

    fn commitImage(store: *Store, commit: ImageCommit) !void {
        const byte_len = commit.allocation.pixels.len;
        const external_id = try store.allocateImageId();
        const usage = try store.usageFor(commit.pane_id);
        try store.images.put(store.gpa, identity(commit.pane_id, commit.image.key), .{
            .metadata = commit.image,
            .pixels = commit.allocation.pixels,
            .shared = commit.allocation.shared,
            .received = commit.received,
            .external_id = external_id,
        });
        commit.allocation.pixels = &.{};
        commit.allocation.shared = null;
        usage.count += 1;
        usage.bytes += byte_len;
        store.total_bytes += byte_len;
        store.damage = true;
    }

    pub fn applyChunk(store: *Store, message: schema.graphics.ImageChunk) !void {
        if (!try store.acceptRevision(message.pane_id, message.revision)) {
            return;
        }
        const entry = store.images.getPtr(identity(message.pane_id, message.key)) orelse
            return error.UnknownGraphicsImage;
        if (message.offset != entry.received) {
            return error.InvalidGraphicsChunkOffset;
        }
        if (entry.chunks == graphics.max_chunks_per_image) {
            return error.GraphicsChunkLimitExceeded;
        }
        const end = std.math.add(usize, entry.received, message.bytes.len) catch
            return error.InvalidGraphicsChunkLength;
        if (end > entry.pixels.len) {
            return error.InvalidGraphicsChunkLength;
        }
        @memcpy(entry.pixels[entry.received..end], message.bytes);
        entry.received = end;
        entry.chunks += 1;
        if (end == entry.pixels.len) {
            const key = entry.metadata.key;
            store.removeOtherGenerations(message.pane_id, key);
            store.damage = true;
        }

        store.noteIngressChange();
    }

    pub fn applyPlacement(store: *Store, message: schema.graphics.Placement) !void {
        if (!try store.acceptRevision(message.pane_id, message.revision)) {
            return;
        }
        const pane_id = message.pane_id;
        const placement = message.placement;
        const image = store.images.get(identity(pane_id, placement.key)) orelse
            return error.UnknownGraphicsImage;
        _ = try placement.sourceRect(image.metadata);
        const key: PlacementIdentity = .{ .pane_id = pane_id, .virtual_id = placement.virtual_id };
        if (store.placements.getPtr(key)) |entry| {
            entry.placement = placement;
            entry.dirty = true;
            store.rememberPartialPlacement(.{ .pane_id = pane_id, .placement = placement, .external_id = entry.external_id });
        } else {
            if (store.panePlacementCount(pane_id) == graphics.max_placements_per_pane) {
                return error.GraphicsPlacementLimitExceeded;
            }
            const usage = try store.usageFor(pane_id);
            const external_id = try store.allocatePlacementId();
            try store.placements.put(store.gpa, key, .{
                .placement = placement,
                .external_id = external_id,
            });
            usage.placements += 1;
            store.rememberPartialPlacement(.{ .pane_id = pane_id, .placement = placement, .external_id = external_id });
        }
        store.damage = true;
        store.noteIngressChange();
    }

    pub fn deleteImage(store: *Store, message: schema.graphics.DeleteImage) !void {
        if (!try store.acceptRevision(message.pane_id, message.revision)) {
            return;
        }
        if (store.deleteImageData(message.pane_id, message.key)) {
            store.noteIngressChange();
        }
    }

    fn deleteImageData(store: *Store, pane_id: schema.PaneId, key: graphics.ImageKey) bool {
        const image_key = identity(pane_id, key);
        const image = store.images.getPtr(image_key) orelse return false;
        store.markRetirePending(image);
        store.removePlacementsForImage(pane_id, key);
        store.collectRetired(pane_id, key.image_id);
        store.damage = true;

        return true;
    }

    fn removeImageData(store: *Store, key: ImageIdentity) void {
        const removed = store.images.fetchRemove(key) orelse return;
        if (removed.value.retire_pending) {
            store.retire_candidates -= 1;
        }
        store.total_bytes -= removed.value.pixels.len;
        store.noteImageRemoved(key.pane_id, removed.value.pixels.len);
        var removed_entry = removed.value;
        store.freePixels(&removed_entry);
        store.queueDelete(.{ .image = removed.value.external_id });
    }

    fn removePlacementsForImage(store: *Store, pane_id: schema.PaneId, key: graphics.ImageKey) void {
        var iterator = store.placements.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.pane_id == pane_id and
                std.meta.eql(entry.value_ptr.placement.key, key))
            {
                if (entry.value_ptr.emitted_image_id) |image_id| {
                    store.queueDelete(.{
                        .placement = .{
                            .image_id = image_id,
                            .placement_id = entry.value_ptr.external_id,
                        },
                    });
                }
                _ = store.placements.removeByPtr(entry.key_ptr);
                store.notePlacementRemoved(pane_id);
            }
        }
    }

    pub fn deletePlacement(store: *Store, message: schema.graphics.DeletePlacement) !void {
        if (!try store.acceptRevision(message.pane_id, message.revision)) {
            return;
        }
        const key: PlacementIdentity = .{
            .pane_id = message.pane_id,
            .virtual_id = message.virtual_id,
        };
        const removed = store.placements.fetchRemove(key) orelse return;
        store.notePlacementRemoved(message.pane_id);
        if (removed.value.emitted_image_id) |image_id| {
            store.queueDelete(.{ .placement = .{
                .image_id = image_id,
                .placement_id = removed.value.external_id,
            } });
        }
        store.collectRetired(message.pane_id, message.key.image_id);
        store.damage = true;
        store.noteIngressChange();
    }

    fn noteIngressChange(store: *Store) void {
        store.ingress_revision +%= 1;
    }

    /// Whether the host terminal accepts zlib-compressed transmissions.
    pub fn setHostZlib(store: *Store, supported: bool) void {
        store.host_zlib = supported;
    }

    pub fn clearPane(store: *Store, pane_id: schema.PaneId) void {
        store.clearPaneData(pane_id, false);
        store.removeRevision(pane_id);
        store.setPaneVisible(pane_id, true) catch {};
    }

    fn clearPaneData(store: *Store, pane_id: schema.PaneId, release_credit: bool) void {
        var placements = store.placements.iterator();
        while (placements.next()) |entry| {
            if (entry.key_ptr.pane_id != pane_id) {
                continue;
            }
            _ = store.placements.removeByPtr(entry.key_ptr);
        }
        var images = store.images.iterator();
        while (images.next()) |entry| {
            if (entry.key_ptr.pane_id != pane_id) {
                continue;
            }
            store.total_bytes -= entry.value_ptr.pixels.len;
            store.freePixels(entry.value_ptr);
            store.queueDelete(.{ .image = entry.value_ptr.external_id });
            _ = store.images.removeByPtr(entry.key_ptr);
        }
        if (store.usage.getPtr(pane_id)) |usage| {
            if (release_credit) {
                usage.released_bytes +|= usage.bytes;
            } else {
                usage.released_bytes = 0;
            }
            usage.count = 0;
            usage.bytes = 0;
            usage.placements = 0;
            store.pruneUsage(pane_id, usage.*);
        }
        store.damage = true;
    }

    pub fn peekCredit(store: *Store) ?Credit {
        var usage = store.usage.iterator();
        while (usage.next()) |entry| {
            if (entry.value_ptr.released_bytes == 0) {
                continue;
            }
            return .{
                .pane_id = entry.key_ptr.*,
                .bytes = entry.value_ptr.released_bytes,
            };
        }
        return null;
    }

    pub fn consumeCredit(store: *Store, credit: Credit) void {
        const usage = store.usage.getPtr(credit.pane_id) orelse unreachable;
        std.debug.assert(credit.bytes != 0 and credit.bytes <= usage.released_bytes);
        usage.released_bytes -= credit.bytes;
        store.pruneUsage(credit.pane_id, usage.*);
    }

    /// Marks every placement for re-emission after the cell geometry or the
    /// layout moved. The emitted image id is kept: a placement re-emitted
    /// under the same image and placement id replaces the host's copy, so no
    /// delete is queued and a large layout cannot overflow the delete ring.
    /// A placement that now clips to nothing is deleted by the writer.
    ///
    /// ```zig
    /// store.invalidatePlacements();
    /// ```
    pub fn invalidatePlacements(store: *Store) void {
        var iterator = store.placements.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.dirty = true;
        }
        store.damage = true;
    }

    pub fn setPaneVisible(store: *Store, pane_id: schema.PaneId, visible: bool) !void {
        if (visible) {
            _ = store.hidden_panes.remove(pane_id);
        } else {
            try store.hidden_panes.put(store.gpa, pane_id, {});
        }

        var iterator = store.placements.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.pane_id != pane_id) {
                continue;
            }
            if (!visible) {
                if (entry.value_ptr.emitted_image_id) |image_id| {
                    store.queueDelete(.{ .placement = .{
                        .image_id = image_id,
                        .placement_id = entry.value_ptr.external_id,
                    } });
                }
            }
            entry.value_ptr.emitted_image_id = null;
            entry.value_ptr.dirty = visible;
        }
        if (!visible) {
            store.collectRetired(pane_id, null);
        }
        store.damage = true;
    }

    pub fn paneVisible(store: *const Store, pane_id: schema.PaneId) bool {
        return !store.hidden_panes.contains(pane_id);
    }

    pub fn hasPaneGraphics(store: *const Store, pane_id: schema.PaneId) bool {
        const usage = store.usage.get(pane_id) orelse return false;
        return usage.count != 0;
    }

    fn allocateImageId(store: *Store) !u32 {
        if (store.next_image_id >= 0x40000000) {
            return error.GraphicsIdExhausted;
        }
        defer store.next_image_id += 1;
        return store.next_image_id;
    }

    fn allocatePlacementId(store: *Store) !u32 {
        if (store.next_placement_id >= 0x40000000) {
            return error.GraphicsIdExhausted;
        }
        defer store.next_placement_id += 1;
        return store.next_placement_id;
    }

    fn queueDelete(store: *Store, value: Delete) void {
        if (store.delete_len == store.delete_queue.len) {
            // Recover with one bounded range delete, then rebuild every
            // Telar-owned low-range image and placement. UI images live in the
            // high range and are not affected.
            store.delete_overflow = true;
            store.damage = true;
            return;
        }
        const index = (store.delete_head + store.delete_len) % store.delete_queue.len;
        store.delete_queue[index] = value;
        store.delete_len += 1;
    }

    fn popDelete(store: *Store) ?Delete {
        if (store.delete_len == 0) {
            return null;
        }
        const value = store.delete_queue[store.delete_head];
        store.delete_head = (store.delete_head + 1) % store.delete_queue.len;
        store.delete_len -= 1;
        return value;
    }

    fn panePlacementCount(store: *const Store, pane_id: schema.PaneId) usize {
        const usage = store.usage.get(pane_id) orelse return 0;
        return usage.placements;
    }

    fn usageFor(store: *Store, pane_id: schema.PaneId) !*PaneUsage {
        const entry = try store.usage.getOrPut(store.gpa, pane_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{};
        }
        return entry.value_ptr;
    }

    fn noteImageRemoved(store: *Store, pane_id: schema.PaneId, bytes: usize) void {
        const usage = store.usage.getPtr(pane_id) orelse return;
        usage.count -= 1;
        usage.bytes -= bytes;
        usage.released_bytes +|= bytes;
        store.pruneUsage(pane_id, usage.*);
    }

    fn notePlacementRemoved(store: *Store, pane_id: schema.PaneId) void {
        const usage = store.usage.getPtr(pane_id) orelse return;
        usage.placements -= 1;
        store.pruneUsage(pane_id, usage.*);
    }

    fn pruneUsage(store: *Store, pane_id: schema.PaneId, usage: PaneUsage) void {
        if (usage.count == 0 and usage.placements == 0 and usage.released_bytes == 0) {
            _ = store.usage.remove(pane_id);
        }
    }

    fn paneLogicalImageCount(store: *const Store, pane_id: schema.PaneId, replacing_id: u32) usize {
        var ids: [graphics.max_images_per_pane]u32 = undefined;
        var count: usize = 0;
        var replacing_present = false;
        var iterator = store.images.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.pane_id != pane_id) {
                continue;
            }
            if (entry.key_ptr.image_id == replacing_id) {
                replacing_present = true;
                continue;
            }
            var duplicate = false;
            for (ids[0..count]) |seen| {
                if (seen != entry.key_ptr.image_id) {
                    continue;
                }
                duplicate = true;
                break;
            }
            if (duplicate) {
                continue;
            }
            ids[count] = entry.key_ptr.image_id;
            count += 1;
        }
        return count + @intFromBool(replacing_present);
    }

    fn hasImageId(store: *const Store, pane_id: schema.PaneId, image_id: u32) bool {
        var iterator = store.images.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.pane_id == pane_id and entry.key_ptr.image_id == image_id) {
                return true;
            }
        }
        return false;
    }

    fn removeOtherGenerations(store: *Store, pane_id: schema.PaneId, current: graphics.ImageKey) void {
        store.retireOtherGenerations(pane_id, current);
    }

    /// A new frame replaces pending work, but not the frame the host terminal
    /// is displaying or a KGP transmission whose `m=0` has not been sent yet.
    fn evictReplacedGenerations(store: *Store, pane_id: schema.PaneId, incoming: graphics.ImageKey) void {
        store.retireOtherGenerations(pane_id, incoming);
    }

    fn retireOtherGenerations(store: *Store, pane_id: schema.PaneId, current: graphics.ImageKey) void {
        var images = store.images.iterator();
        while (images.next()) |entry| {
            if (entry.key_ptr.pane_id != pane_id or
                entry.key_ptr.image_id != current.image_id or
                entry.key_ptr.generation == current.generation)
            {
                continue;
            }
            store.markRetirePending(entry.value_ptr);
        }
        store.collectRetired(pane_id, current.image_id);
    }

    fn markRetirePending(store: *Store, image: *ImageEntry) void {
        if (!image.retire_pending) {
            image.retire_pending = true;
            store.retire_candidates += 1;
        }
    }

    fn exteriorGenerationLive(store: *const Store, key: ImageIdentity, external_id: u32) bool {
        if (store.partial) |partial| {
            if (std.meta.eql(partial.key, key)) {
                return true;
            }
        }
        var placements = store.placements.iterator();
        while (placements.next()) |entry| {
            if (entry.key_ptr.pane_id != key.pane_id) {
                continue;
            }
            if (entry.value_ptr.emitted_image_id == external_id or
                (entry.value_ptr.placement.key.image_id == key.image_id and
                    entry.value_ptr.placement.key.generation == key.generation))
            {
                return true;
            }
        }
        return false;
    }

    fn collectRetired(store: *Store, pane_id: ?schema.PaneId, image_id: ?u32) void {
        // The writer asks after every placement it emits; with nothing
        // marked for retirement the whole sweep is skipped.
        if (store.retire_candidates == 0) {
            return;
        }
        // Retransmissions bypass the logical image count, so sweep in bounded
        // batches instead of assuming one fixed array holds every generation.
        var retired: [graphics.max_images_per_pane]ImageIdentity = undefined;
        while (true) {
            var count: usize = 0;
            var images = store.images.iterator();
            while (images.next()) |entry| {
                if (pane_id) |expected| {
                    if (entry.key_ptr.pane_id != expected) {
                        continue;
                    }
                }
                if (image_id) |expected| {
                    if (entry.key_ptr.image_id != expected) {
                        continue;
                    }
                }
                if (!entry.value_ptr.retire_pending or
                    store.exteriorGenerationLive(entry.key_ptr.*, entry.value_ptr.external_id) or
                    !store.sharedPixelsConsumed(entry.value_ptr))
                {
                    continue;
                }
                if (comptime diagnostics.enabled) {
                    if (entry.value_ptr.emitted_shared and entry.value_ptr.transmitted_ns != 0 and
                        store.clock_ns != 0)
                    {
                        store.retire_latency.observe(store.clock_ns -| entry.value_ptr.transmitted_ns);
                    }
                }
                retired[count] = entry.key_ptr.*;
                count += 1;
                if (count == retired.len) {
                    break;
                }
            }
            if (count == 0) {
                return;
            }
            for (retired[0..count]) |key| store.removeImageData(key);
        }
    }

    fn rememberPartialPlacement(store: *Store, remembered: PartialPlacement) void {
        const partial = if (store.partial) |*value| value else return;
        if (partial.key.pane_id != remembered.pane_id or
            partial.key.image_id != remembered.placement.key.image_id or
            partial.key.generation != remembered.placement.key.generation)
        {
            return;
        }
        for (partial.fallbacks[0..partial.fallback_count]) |*fallback| {
            if (fallback.placement.virtual_id != remembered.placement.virtual_id) {
                continue;
            }
            fallback.* = .{ .placement = remembered.placement, .external_id = remembered.external_id };
            return;
        }
        if (partial.fallback_count == partial.fallbacks.len) {
            return;
        }
        partial.fallbacks[partial.fallback_count] = .{
            .placement = remembered.placement,
            .external_id = remembered.external_id,
        };
        partial.fallback_count += 1;
    }

    fn capturePartialPlacements(store: *Store) void {
        if (store.partial == null) {
            return;
        }
        var placements = store.placements.iterator();
        while (placements.next()) |entry| {
            store.rememberPartialPlacement(.{
                .pane_id = entry.key_ptr.pane_id,
                .placement = entry.value_ptr.placement,
                .external_id = entry.value_ptr.external_id,
            });
        }
    }

    fn removeIncomplete(store: *Store, pane_id: schema.PaneId) void {
        var placements = store.placements.iterator();
        while (placements.next()) |entry| {
            if (entry.key_ptr.pane_id != pane_id) {
                continue;
            }
            const image = store.images.get(identity(
                pane_id,
                entry.value_ptr.placement.key,
            )) orelse {
                _ = store.placements.removeByPtr(entry.key_ptr);
                store.notePlacementRemoved(pane_id);
                store.damage = true;
                continue;
            };
            if (image.received != image.pixels.len) {
                _ = store.placements.removeByPtr(entry.key_ptr);
                store.notePlacementRemoved(pane_id);
                store.damage = true;
            }
        }
        var iterator = store.images.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.pane_id != pane_id or
                entry.value_ptr.received == entry.value_ptr.pixels.len)
            {
                continue;
            }
            store.total_bytes -= entry.value_ptr.pixels.len;
            store.noteImageRemoved(pane_id, entry.value_ptr.pixels.len);
            store.freePixels(entry.value_ptr);
            store.queueDelete(.{ .image = entry.value_ptr.external_id });
            _ = store.images.removeByPtr(entry.key_ptr);
            store.damage = true;
        }
    }

    fn revisionState(store: *Store, pane_id: schema.PaneId) !*RevisionState {
        const entry = try store.revisions.getOrPut(store.gpa, pane_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{};
        }
        return entry.value_ptr;
    }

    fn acceptRevision(store: *Store, pane_id: schema.PaneId, value: u64) !bool {
        const state = try store.revisionState(pane_id);
        if (state.awaiting_snapshot) {
            return false;
        }
        if (state.snapshot) |snapshot| {
            if (value != snapshot) {
                state.awaiting_snapshot = true;
                state.snapshot = null;
                return error.GraphicsResyncRequired;
            }
            return true;
        }
        if (value < state.latest) {
            return false;
        }
        state.latest = value;
        return true;
    }

    fn removeRevision(store: *Store, pane_id: schema.PaneId) void {
        _ = store.revisions.remove(pane_id);
    }
};

fn identity(pane_id: schema.PaneId, key: graphics.ImageKey) ImageIdentity {
    return .{ .pane_id = pane_id, .image_id = key.image_id, .generation = key.generation };
}

pub const KittyGraphicsWriter = struct {
    store: *Store,
    layout_snapshot: *const layout.Snapshot,
    cell_width: u16,
    cell_height: u16,
    /// Encoded-byte budget for this pass. The client boosts it while host
    /// input is idle; the default protects the keystroke echo.
    budget: usize = transmission_budget_per_frame,
    /// Emission counts accumulated across this writer's passes; the client
    /// folds them into its telemetry after each flush.
    stats: Stats = .{},
    /// Monotonic time of this pass, for retire latency. Zero disables it.
    now_ns: u64 = 0,
    /// Which escapes this pass may emit. `control` rides inside a cell frame
    /// and therefore never streams pixels; `bulk` is the paced media pass.
    mode: Mode = .bulk,

    pub const Mode = enum {
        /// Shared names, placements and deletes: a few hundred bytes per
        /// image, so they fit the synchronized cell update without delaying
        /// it. Images that need inline pixels stay damaged for `bulk`.
        control,
        /// Everything the byte budget allows, chunked transfers included.
        bulk,
    };

    pub const Stats = struct {
        /// Images handed to the host as a shared-memory name.
        shared_images: u64 = 0,
        /// Images whose inline transmission closed, compressed or raw.
        inline_images: u64 = 0,
        /// The subset of `inline_images` that shipped as a zlib stream.
        compressed_images: u64 = 0,
        /// Chunk-emission calls; divided by `inline_images` this is the
        /// passes-per-image pacing the budget policy produces.
        transmission_passes: u64 = 0,
        /// Passes that advanced a deflate by at least one slice.
        compress_passes: u64 = 0,
    };

    pub fn writeOpaque(context: *anyopaque, writer: *Io.Writer) Io.Writer.Error!usize {
        const self: *KittyGraphicsWriter = @ptrCast(@alignCast(context));
        return self.write(writer);
    }

    pub fn write(self: *KittyGraphicsWriter, writer: *Io.Writer) Io.Writer.Error!usize {
        self.store.beginPresentation(self.now_ns);
        if (!self.store.damage or self.cell_width == 0 or self.cell_height == 0) {
            return 0;
        }
        self.store.collectRetired(null, null);
        // An open chunked transfer owns the stream until the bulk pass closes
        // it; a control pass may not even emit a delete in between.
        if (self.mode == .control and self.store.partial != null) {
            return 0;
        }
        var written: usize = 0;
        var budget: usize = self.budget;
        var compress_budget: usize = compression_slice_per_frame;
        var compressing = false;
        var bulk_pending = false;

        // An open chunked transfer owns the graphics stream: the protocol
        // forbids other graphics escapes between its chunks, so it either
        // resumes first or is closed before anything else is emitted.
        if (self.store.partial) |partial| {
            const alive = if (self.store.images.getPtr(partial.key)) |entry|
                entry.external_id == partial.external_id
            else
                false;
            if (!alive) {
                // The image was replaced or deleted mid-transfer. An empty
                // final chunk closes the stream; the length mismatch makes
                // the terminal discard it, silently under q=2.
                written += try writeTransmissionAbort(writer);
                written += try writeDeleteImage(writer, partial.external_id);
                self.store.partial = null;
            } else {
                const entry = self.store.images.getPtr(partial.key).?;
                // The open transfer's header already declared its encoding,
                // so the resume reads the buffer that header described.
                const source = if (partial.compressed) entry.compressed.? else entry.pixels;
                self.stats.transmission_passes += 1;
                const progress = try writeTransmissionChunks(writer, .{
                    .external_id = partial.external_id,
                    .image = entry.metadata,
                    .pixels = source,
                    .start_offset = partial.offset,
                    .budget = budget,
                    .compressed = partial.compressed,
                });
                written += progress.written;
                if (progress.offset < source.len) {
                    self.store.partial.?.offset = progress.offset;
                    // Damage stays set; the next frame resumes here.
                    return written;
                }
                self.store.completeTransmission(entry, .inline_data);
                self.stats.inline_images += 1;
                self.stats.compressed_images += @intFromBool(partial.compressed);
                written += try self.writeFallbackPlacements(writer, .{ .partial = partial, .image = entry.* });
                self.store.collectRetired(
                    partial.key.pane_id,
                    partial.key.image_id,
                );
                budget -= @min(budget, progress.written);
            }
        }
        if (self.store.delete_overflow) {
            written += try writeDeleteImageRange(writer, 1, 0x3fffffff);
            self.store.recoverDeleteOverflow();
        }
        while (self.store.popDelete()) |deletion| written += switch (deletion) {
            .image => |image_id| try writeDeleteImage(writer, image_id),
            .placement => |placement| try writeDeletePlacement(
                writer,
                placement.image_id,
                placement.placement_id,
            ),
        };

        var images = self.store.images.iterator();
        while (images.next()) |entry| {
            if (!self.store.paneVisible(entry.key_ptr.pane_id)) {
                continue;
            }
            const image = entry.value_ptr;
            if (image.received != image.pixels.len or image.transmitted) {
                continue;
            }
            // Budget spent: the rest keeps its damage and waits for the next
            // frame, so no image can park itself in front of a keystroke.
            if (budget == 0) {
                return written;
            }
            if (image.shared) |*shared| {
                if (!image.force_direct and self.store.shared_memory) {
                    const emitted = try writeSharedTransmission(writer, .{
                        .external_id = image.external_id,
                        .image = image.metadata,
                        .name = shared.slice(),
                    });
                    written += emitted;
                    self.store.completeTransmission(image, .shared_memory);
                    self.stats.shared_images += 1;
                    budget -= @min(budget, emitted);
                    continue;
                }
            }
            if (self.mode == .control) {
                bulk_pending = true;
                continue;
            }
            // A still-deflating image keeps its wire budget for the others;
            // its own transmission starts once the stream is finished.
            const compress_budget_before = compress_budget;
            const source_ready = self.store.advanceCompression(image, &compress_budget);
            self.stats.compress_passes +=
                @intFromBool(compress_budget != compress_budget_before);
            if (!source_ready) {
                compressing = true;
                continue;
            }
            const compressed = image.compressed != null;
            const source = image.compressed orelse image.pixels;
            self.stats.transmission_passes += 1;
            const progress = try writeTransmissionChunks(writer, .{
                .external_id = image.external_id,
                .image = image.metadata,
                .pixels = source,
                .start_offset = 0,
                .budget = budget,
                .compressed = compressed,
            });
            written += progress.written;
            if (progress.offset < source.len) {
                self.store.partial = .{
                    .key = entry.key_ptr.*,
                    .external_id = image.external_id,
                    .offset = progress.offset,
                    .compressed = compressed,
                };
                self.store.capturePartialPlacements();
                // The open transfer forbids emitting anything else.
                return written;
            }
            self.store.completeTransmission(image, .inline_data);
            self.stats.inline_images += 1;
            self.stats.compressed_images += @intFromBool(compressed);
            budget -= @min(budget, progress.written);
        }

        var placements = self.store.placements.iterator();
        while (placements.next()) |entry| {
            if (!self.store.paneVisible(entry.key_ptr.pane_id)) {
                continue;
            }
            const placement = entry.value_ptr;
            if (!placement.dirty) {
                continue;
            }
            const image = self.store.images.get(identity(
                entry.key_ptr.pane_id,
                placement.placement.key,
            )) orelse continue;
            if (!image.transmitted) {
                continue;
            }
            const output = self.geometry(.{
                .pane_id = entry.key_ptr.pane_id,
                .placement = placement.placement,
                .image = image.metadata,
            }) orelse {
                if (placement.emitted_image_id) |previous_image_id| {
                    written += try writeDeletePlacement(
                        writer,
                        previous_image_id,
                        placement.external_id,
                    );
                }
                placement.emitted_image_id = null;
                placement.dirty = false;
                self.store.collectRetired(
                    entry.key_ptr.pane_id,
                    placement.placement.key.image_id,
                );
                continue;
            };
            written += try writePlacement(writer, .{
                .image_id = image.external_id,
                .placement_id = placement.external_id,
                .value = output,
                .z = placement.placement.z_index,
            });
            if (placement.emitted_image_id) |previous_image_id| {
                if (previous_image_id != image.external_id) {
                    written += try writeDeletePlacement(
                        writer,
                        previous_image_id,
                        placement.external_id,
                    );
                }
            }
            placement.emitted_image_id = image.external_id;
            placement.dirty = false;
            self.store.collectRetired(
                entry.key_ptr.pane_id,
                placement.placement.key.image_id,
            );
        }
        self.store.damage = bulk_pending or compressing or self.store.delete_len != 0 or
            self.store.delete_overflow or self.store.hasPendingSharedRelease();
        return written;
    }

    /// Presents a completed frame even if a newer generation arrived while
    /// it crossed the host terminal. This bounds the queue to the visible,
    /// in-flight and latest generations without starving continuous repaint.
    fn writeFallbackPlacements(self: *KittyGraphicsWriter, writer: *Io.Writer, frame: FallbackFrame) Io.Writer.Error!usize {
        if (!self.store.paneVisible(frame.partial.key.pane_id)) {
            return 0;
        }
        var written: usize = 0;
        for (frame.partial.fallbacks[0..frame.partial.fallback_count]) |fallback| {
            const key: PlacementIdentity = .{
                .pane_id = frame.partial.key.pane_id,
                .virtual_id = fallback.placement.virtual_id,
            };
            const placement = self.store.placements.getPtr(key) orelse continue;
            if (placement.external_id != fallback.external_id or
                placement.placement.key.image_id != frame.partial.key.image_id or
                placement.placement.key.generation < frame.partial.key.generation)
            {
                continue;
            }
            const output = self.geometry(.{
                .pane_id = frame.partial.key.pane_id,
                .placement = fallback.placement,
                .image = frame.image.metadata,
            }) orelse continue;
            written += try writePlacement(writer, .{
                .image_id = frame.image.external_id,
                .placement_id = placement.external_id,
                .value = output,
                .z = fallback.placement.z_index,
            });
            if (placement.emitted_image_id) |previous_image_id| {
                if (previous_image_id != frame.image.external_id) {
                    written += try writeDeletePlacement(
                        writer,
                        previous_image_id,
                        placement.external_id,
                    );
                }
            }
            placement.emitted_image_id = frame.image.external_id;
            placement.dirty = !std.meta.eql(placement.placement, fallback.placement);
        }
        return written;
    }

    fn geometry(self: *const KittyGraphicsWriter, geometry_input: PlacementGeometry) ?OutputPlacement {
        const view = self.layout_snapshot.find(geometry_input.pane_id) orelse return null;
        const source = geometry_input.placement.sourceRect(geometry_input.image) catch return null;
        const source_width: u32 = @intCast(source.width);
        const source_height: u32 = @intCast(source.height);
        const width, const height = destinationSize(.{
            .placement = geometry_input.placement,
            .source_width = source_width,
            .source_height = source_height,
            .cell_width = self.cell_width,
            .cell_height = self.cell_height,
        });
        if (width == 0 or height == 0) {
            return null;
        }
        const destination: graphics.Rect = .{
            .x = (@as(i64, view.content.x) + geometry_input.placement.x) * self.cell_width + geometry_input.placement.offset_x,
            .y = (@as(i64, view.content.y) + geometry_input.placement.y) * self.cell_height + geometry_input.placement.offset_y,
            .width = width,
            .height = height,
        };
        const bounds: graphics.Rect = .{
            .x = @as(i64, view.content.x) * self.cell_width,
            .y = @as(i64, view.content.y) * self.cell_height,
            .width = @as(u64, view.content.w) * self.cell_width,
            .height = @as(u64, view.content.h) * self.cell_height,
        };
        const clipped = graphics.clipScaled(destination, .{
            .x = source.x,
            .y = source.y,
            .width = source_width,
            .height = source_height,
        }, bounds) orelse return null;
        const pixel_x: u64 = @intCast(clipped.destination.x);
        const pixel_y: u64 = @intCast(clipped.destination.y);
        return .{
            .column = @intCast(pixel_x / self.cell_width),
            .row = @intCast(pixel_y / self.cell_height),
            .offset_x = @intCast(pixel_x % self.cell_width),
            .offset_y = @intCast(pixel_y % self.cell_height),
            .source_x = @intCast(clipped.source.x),
            .source_y = @intCast(clipped.source.y),
            .source_width = @intCast(clipped.source.width),
            .source_height = @intCast(clipped.source.height),
            .columns = @intCast(std.math.divCeil(u64, clipped.destination.width + pixel_x % self.cell_width, self.cell_width) catch 1),
            .rows = @intCast(std.math.divCeil(u64, clipped.destination.height + pixel_y % self.cell_height, self.cell_height) catch 1),
        };
    }
};

const DestinationSizeInput = struct {
    placement: graphics.Placement,
    source_width: u32,
    source_height: u32,
    cell_width: u16,
    cell_height: u16,
};

fn destinationSize(size_input: DestinationSizeInput) struct { u64, u64 } {
    if (size_input.placement.columns == 0 and size_input.placement.rows == 0) {
        return .{ size_input.source_width, size_input.source_height };
    }
    if (size_input.placement.columns != 0 and size_input.placement.rows != 0) {
        return .{
            @as(u64, size_input.placement.columns) * size_input.cell_width -| size_input.placement.offset_x,
            @as(u64, size_input.placement.rows) * size_input.cell_height -| size_input.placement.offset_y,
        };
    }
    if (size_input.placement.columns != 0) {
        const width = @as(u64, size_input.placement.columns) * size_input.cell_width -| size_input.placement.offset_x;
        return .{ width, width * size_input.source_height / size_input.source_width };
    }
    const height = @as(u64, size_input.placement.rows) * size_input.cell_height -| size_input.placement.offset_y;
    return .{ height * size_input.source_width / size_input.source_height, height };
}

test "capability query and probe identities are exact" {
    try std.testing.expectEqualStrings(
        "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\" ++
            "\x1b_Gi=32,s=1,v=1,a=q,t=d,f=24,o=z;eJxjYGAAAAADAAE=\x1b\\" ++
            "\x1b[14t\x1b[16t\x1b[?1016$p\x1b[c",
        capability_query,
    );
    try std.testing.expectEqual(@as(u32, 31), query_image_id);
    try std.testing.expectEqual(@as(u32, 32), zlib_query_image_id);
}

test "automatic sidebar renderer falls back while capability is absent" {
    try std.testing.expectEqual(ResolvedSidebarRendering.cells, try SidebarRendering.automatic.resolve(.unknown));
    try std.testing.expectEqual(ResolvedSidebarRendering.cells, try SidebarRendering.automatic.resolve(.unsupported));
    try std.testing.expectEqual(ResolvedSidebarRendering.kitty_hybrid, try SidebarRendering.automatic.resolve(.supported));
    try std.testing.expectError(error.KittyGraphicsUnsupported, SidebarRendering.kitty_hybrid.resolve(.unsupported));
}

test "direct transmission chunks payload without changing pixels" {
    var pixels: [3073]u8 = undefined;
    for (&pixels, 0..) |*byte, index| byte.* = @truncate(index);
    var output: [8192]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    _ = try writeTransmission(&writer, .{
        .external_id = 9,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgba,
            .width = 3073,
            .height = 1,
            .byte_len = pixels.len,
        },
        .pixels = &pixels,
    });
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "\x1b_Ga=t,f=32,s=3073,v=1,t=d,i=9,q=2,m=1;"));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b\\\x1b_Gm=0;") != null);
}

test "exterior IDs do not collide across panes with identical child IDs" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const metadata: graphics.Image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applyImage(.{ .pane_id = @enumFromInt(1), .revision = 1, .image = metadata });
    try store.applyImage(.{ .pane_id = @enumFromInt(2), .revision = 1, .image = metadata });
    const first = store.images.get(identity(@enumFromInt(1), metadata.key)).?.external_id;
    const second = store.images.get(identity(@enumFromInt(2), metadata.key)).?.external_id;
    try std.testing.expect(first != second);
    try std.testing.expect(first < 0x40000000 and second < 0x40000000);
}

test "unchanged graphics emit no work and resize does not retransmit pixels" {
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 10, .rows = 5 } });

    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const metadata: graphics.Image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applyImage(.{ .pane_id = @enumFromInt(1), .revision = 1, .image = metadata });
    try store.applyChunk(.{
        .pane_id = @enumFromInt(1),
        .revision = 1,
        .key = metadata.key,
        .offset = 0,
        .bytes = &.{ 1, 2, 3, 255 },
    });
    try store.applyPlacement(.{
        .pane_id = @enumFromInt(1),
        .revision = 1,
        .placement = .{
            .key = metadata.key,
            .virtual_id = 1,
            .placement_id = 1,
            .x = 0,
            .y = 0,
        },
    });
    var first_bytes: [4096]u8 = undefined;
    var first_writer = Io.Writer.fixed(&first_bytes);
    const layout_snapshot = model.layoutSnapshot(.{ .w = 10, .h = 5 });
    var graphics_writer: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = layout_snapshot,
        .cell_width = 10,
        .cell_height = 20,
    };
    try std.testing.expect((try graphics_writer.write(&first_writer)) != 0);
    try std.testing.expect(std.mem.indexOf(u8, first_writer.buffered(), "a=t") != null);

    var idle_bytes: [64]u8 = undefined;
    var idle_writer = Io.Writer.fixed(&idle_bytes);
    try std.testing.expectEqual(@as(usize, 0), try graphics_writer.write(&idle_writer));

    store.invalidatePlacements();
    var resize_bytes: [1024]u8 = undefined;
    var resize_writer = Io.Writer.fixed(&resize_bytes);
    try std.testing.expect((try graphics_writer.write(&resize_writer)) != 0);
    try std.testing.expect(std.mem.indexOf(u8, resize_writer.buffered(), "a=p") != null);
    try std.testing.expect(std.mem.indexOf(u8, resize_writer.buffered(), "a=t") == null);

    try store.setPaneVisible(@enumFromInt(1), false);
    var hidden_bytes: [1024]u8 = undefined;
    var hidden_writer = Io.Writer.fixed(&hidden_bytes);
    try std.testing.expect((try graphics_writer.write(&hidden_writer)) != 0);
    try std.testing.expect(std.mem.indexOf(u8, hidden_writer.buffered(), "a=d") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_writer.buffered(), "a=t") == null);

    try store.setPaneVisible(@enumFromInt(1), true);
    var visible_bytes: [1024]u8 = undefined;
    var visible_writer = Io.Writer.fixed(&visible_bytes);
    try std.testing.expect((try graphics_writer.write(&visible_writer)) != 0);
    try std.testing.expect(std.mem.indexOf(u8, visible_writer.buffered(), "a=p") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible_writer.buffered(), "a=t") == null);
}

test "image transmission is paced across frames by the byte budget" {
    // Regression: the writer base64-encoded whole images inside one frame's
    // flush, so a large child image sat between a keystroke and its echo.
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 10, .rows = 5 } });

    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const metadata: graphics.Image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 512,
        .height = 256,
        .byte_len = 512 * 256 * 4,
    };
    const pixels = try std.testing.allocator.alloc(u8, 512 * 256 * 4);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0xab);
    try store.applyImage(.{ .pane_id = @enumFromInt(1), .revision = 1, .image = metadata });
    try store.applyChunk(.{
        .pane_id = @enumFromInt(1),
        .revision = 1,
        .key = metadata.key,
        .offset = 0,
        .bytes = pixels,
    });
    try store.applyPlacement(.{
        .pane_id = @enumFromInt(1),
        .revision = 1,
        .placement = .{
            .key = metadata.key,
            .virtual_id = 1,
            .placement_id = 1,
            .x = 0,
            .y = 0,
        },
    });

    const layout_snapshot = model.layoutSnapshot(.{ .w = 10, .h = 5 });
    var graphics_writer: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = layout_snapshot,
        .cell_width = 10,
        .cell_height = 20,
    };
    const frame_buffer = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(frame_buffer);

    // One frame spends at most the budget plus one chunk of overshoot.
    var writer = Io.Writer.fixed(frame_buffer);
    const first = try graphics_writer.write(&writer);
    try std.testing.expect(first <= transmission_budget_per_frame + 8192);

    var frames: usize = 1;
    var placed = false;
    while (store.damage) {
        frames += 1;
        try std.testing.expect(frames < 32);
        var next = Io.Writer.fixed(frame_buffer);
        _ = try graphics_writer.write(&next);
        if (std.mem.indexOf(u8, next.buffered(), "a=p") != null) {
            placed = true;
        }
    }
    try std.testing.expect(frames > 1);
    try std.testing.expect(placed);

    // Idle afterwards: no work left.
    var idle = Io.Writer.fixed(frame_buffer);
    try std.testing.expectEqual(@as(usize, 0), try graphics_writer.write(&idle));
}

/// One pane holding a complete 512x256 RGBA image with one placement, the
/// shape the budget and compression tests all exercise.
const TransmissionFixture = struct {
    const metadata: graphics.Image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 512,
        .height = 256,
        .byte_len = 512 * 256 * 4,
    };

    model: multiplexer.Model,
    store: Store,

    fn init(pixels: []const u8) !TransmissionFixture {
        std.debug.assert(pixels.len == metadata.byte_len);
        const location: schema.TabLocation = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        };
        var model = multiplexer.Model.init(std.testing.allocator);
        errdefer model.deinit();
        try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 10, .rows = 5 } });
        var store = Store.init(std.testing.allocator);
        errdefer store.deinit();
        try store.applyImage(.{ .pane_id = @enumFromInt(1), .revision = 1, .image = metadata });
        try store.applyChunk(.{
            .pane_id = @enumFromInt(1),
            .revision = 1,
            .key = metadata.key,
            .offset = 0,
            .bytes = pixels,
        });
        try store.applyPlacement(.{
            .pane_id = @enumFromInt(1),
            .revision = 1,
            .placement = .{
                .key = metadata.key,
                .virtual_id = 1,
                .placement_id = 1,
                .x = 0,
                .y = 0,
            },
        });
        return .{ .model = model, .store = store };
    }

    fn deinit(fixture: *TransmissionFixture) void {
        fixture.store.deinit();
        fixture.model.deinit();
    }

    fn writer(fixture: *TransmissionFixture, budget: usize) KittyGraphicsWriter {
        return .{
            .store = &fixture.store,
            .layout_snapshot = fixture.model.layoutSnapshot(.{ .w = 10, .h = 5 }),
            .cell_width = 10,
            .cell_height = 20,
            .budget = budget,
        };
    }
};

/// Concatenates the base64-decoded payloads of every `a=t` transmission and
/// `m=` continuation chunk in `bytes`, in stream order.
fn decodeTransmissionPayloads(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var collected: Io.Writer.Allocating = .init(gpa);
    defer collected.deinit();
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, search, "\x1b_G")) |start| {
        const end = std.mem.indexOfPos(u8, bytes, start, "\x1b\\") orelse break;
        search = end + 2;
        const body = bytes[start + 3 .. end];
        const separator = std.mem.indexOfScalar(u8, body, ';') orelse continue;
        const control = body[0..separator];
        if (std.mem.indexOf(u8, control, "a=t") == null and
            !std.mem.startsWith(u8, control, "m="))
        {
            continue;
        }
        const encoded = body[separator + 1 ..];
        const Decoder = std.base64.standard.Decoder;
        var decoded: [4096]u8 = undefined;
        const decoded_len = try Decoder.calcSizeForSlice(encoded);
        try Decoder.decode(decoded[0..decoded_len], encoded);
        try collected.writer.writeAll(decoded[0..decoded_len]);
    }
    return collected.toOwnedSlice();
}

fn inflateExact(gpa: std.mem.Allocator, compressed: []const u8, expected_len: usize) ![]u8 {
    var input = std.Io.Reader.fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&input, .zlib, &window);
    const inflated = try gpa.alloc(u8, expected_len);
    errdefer gpa.free(inflated);
    const inflated_len = try decompress.reader.readSliceShort(inflated);
    try std.testing.expectEqual(expected_len, inflated_len);
    return inflated;
}

test "a large explicit budget transmits and places a frame in one pass" {
    const pixels = try std.testing.allocator.alloc(u8, TransmissionFixture.metadata.byte_len);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0xab);
    var fixture = try TransmissionFixture.init(pixels);
    defer fixture.deinit();

    var graphics_writer = fixture.writer(transmission_budget_per_frame * 8);
    const frame_buffer = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(frame_buffer);
    var writer = Io.Writer.fixed(frame_buffer);
    _ = try graphics_writer.write(&writer);

    // The whole image and its placement went out because this test explicitly
    // supplied enough budget for one pass.
    try std.testing.expect(fixture.store.partial == null);
    try std.testing.expect(!fixture.store.damage);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a=p") != null);
    try std.testing.expectEqual(@as(u64, 1), graphics_writer.stats.inline_images);
    try std.testing.expectEqual(@as(u64, 1), graphics_writer.stats.transmission_passes);
    try std.testing.expectEqual(@as(u64, 0), graphics_writer.stats.compressed_images);
}

test "performance probe measures compression work outside the presentation turn" {
    const pixels = try std.testing.allocator.alloc(u8, TransmissionFixture.metadata.byte_len);
    defer std.testing.allocator.free(pixels);
    var prng = std.Random.DefaultPrng.init(9);
    for (pixels, 0..) |*byte, index| {
        byte.* = if (index % 16 == 3) prng.random().int(u8) else 0x30;
    }
    var turns: [20]u64 = undefined;
    var totals: [20]u64 = undefined;
    for (&turns, &totals) |*turn, *total| {
        var fixture = try TransmissionFixture.init(pixels);
        defer fixture.deinit();
        var scheduler: TestCompressionScheduler = .{};
        fixture.store.host_zlib = true;
        if (comptime @hasField(Store, "compression_scheduler")) {
            fixture.store.compression_scheduler = .{ .context = &scheduler, .start = TestCompressionScheduler.schedule };
        }
        const image = fixture.store.images.getPtr(identity(@enumFromInt(1), TransmissionFixture.metadata.key)).?;
        turn.* = 0;
        const started = Io.Clock.awake.now(std.testing.io).nanoseconds;
        while (true) {
            var budget: usize = compression_slice_per_frame;
            const before = Io.Clock.awake.now(std.testing.io).nanoseconds;
            const done = fixture.store.advanceCompression(image, &budget);
            turn.* = @max(turn.*, @as(u64, @intCast(Io.Clock.awake.now(std.testing.io).nanoseconds - before)));
            if (comptime @hasField(Store, "compression_scheduler")) {
                scheduler.complete(&fixture.store);
            }
            if (done) {
                break;
            }
        }
        total.* = @intCast(Io.Clock.awake.now(std.testing.io).nanoseconds - started);
        const inflated = try inflateExact(std.testing.allocator, image.compressed.?, pixels.len);
        defer std.testing.allocator.free(inflated);
        try std.testing.expectEqualSlices(u8, pixels, inflated);
    }
    for ([_][]u64{ &turns, &totals }, [_][]const u8{ "compression_max_turn", "compression_total" }) |values, name| {
        std.mem.sort(u64, values, {}, std.sort.asc(u64));
        std.debug.print("PERF {s} n=20 p50_ns={d} p95_ns={d} p99_ns={d}\n", .{ name, values[10], values[18], values[19] });
    }
}

const TestCompressionScheduler = struct {
    pending: ?*Compression = null,

    fn schedule(context: *anyopaque, job: *Compression) anyerror!void {
        const scheduler: *TestCompressionScheduler = @ptrCast(@alignCast(context));
        try std.testing.expect(scheduler.pending == null);
        scheduler.pending = job;
    }

    fn complete(scheduler: *TestCompressionScheduler, store: *Store) void {
        const job = scheduler.pending orelse return;
        store.completeCompression(Compression.run(job));
        scheduler.pending = null;
    }
};

test "async compression owns its input and emits the same pixels" {
    const pixels = try std.testing.allocator.alloc(u8, TransmissionFixture.metadata.byte_len);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0x30);
    var fixture = try TransmissionFixture.init(pixels);
    defer fixture.deinit();
    var scheduler: TestCompressionScheduler = .{};
    fixture.store.host_zlib = true;
    fixture.store.compression_scheduler = .{ .context = &scheduler, .start = TestCompressionScheduler.schedule };
    var graphics_writer = fixture.writer(transmission_budget_per_frame);
    var collected: Io.Writer.Allocating = .init(std.testing.allocator);
    defer collected.deinit();
    const buffer = try std.testing.allocator.alloc(u8, transmission_budget_per_frame * 2);
    defer std.testing.allocator.free(buffer);
    var turns: usize = 0;
    while (fixture.store.damage) {
        turns += 1;
        try std.testing.expect(turns < 32);
        var writer = Io.Writer.fixed(buffer);
        _ = try graphics_writer.write(&writer);
        try collected.writer.writeAll(writer.buffered());
        if (scheduler.pending) |job| {
            if (turns == 1) {
                try std.testing.expectEqual(@as(usize, 2), job.allocating.written().len);
            }
            const image = fixture.store.images.getPtr(identity(@enumFromInt(1), TransmissionFixture.metadata.key)).?;
            try std.testing.expect(job.input.ptr != image.pixels.ptr);
            try std.testing.expect(job.input_len <= compression_slice_per_frame);
            scheduler.complete(&fixture.store);
        }
    }
    const compressed = try decodeTransmissionPayloads(std.testing.allocator, collected.written());
    defer std.testing.allocator.free(compressed);
    const inflated = try inflateExact(std.testing.allocator, compressed, pixels.len);
    defer std.testing.allocator.free(inflated);
    try std.testing.expectEqualSlices(u8, pixels, inflated);
    try std.testing.expectEqual(@as(u64, 1), graphics_writer.stats.compressed_images);
}

test "an image deleted during compression releases its orphan only after completion" {
    const pixels = try std.testing.allocator.alloc(u8, TransmissionFixture.metadata.byte_len);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0x30);
    var fixture = try TransmissionFixture.init(pixels);
    defer fixture.deinit();
    var scheduler: TestCompressionScheduler = .{};
    fixture.store.host_zlib = true;
    fixture.store.compression_scheduler = .{ .context = &scheduler, .start = TestCompressionScheduler.schedule };
    const image_key = identity(@enumFromInt(1), TransmissionFixture.metadata.key);
    const image = fixture.store.images.getPtr(image_key).?;
    var budget: usize = compression_slice_per_frame;
    try std.testing.expect(!fixture.store.advanceCompression(image, &budget));
    try std.testing.expect(scheduler.pending != null);
    fixture.store.removeImageData(image_key);
    try std.testing.expect(fixture.store.orphan_compression);
    scheduler.complete(&fixture.store);
    try std.testing.expect(fixture.store.pending_compression == null);
    try std.testing.expect(!fixture.store.orphan_compression);
}

test "a zlib host ships a deflated stream that inflates to the pixels" {
    const pixels = try std.testing.allocator.alloc(u8, TransmissionFixture.metadata.byte_len);
    defer std.testing.allocator.free(pixels);
    // Browser-frame shape: flat fills with a sparse noise band.
    var prng = std.Random.DefaultPrng.init(9);
    for (pixels, 0..) |*byte, index| {
        byte.* = if (index % 16 == 3) prng.random().int(u8) else 0x30;
    }
    var fixture = try TransmissionFixture.init(pixels);
    defer fixture.deinit();
    fixture.store.host_zlib = true;

    var graphics_writer = fixture.writer(transmission_budget_per_frame);
    const frame_buffer = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(frame_buffer);
    var collected: Io.Writer.Allocating = .init(std.testing.allocator);
    defer collected.deinit();

    var frames: usize = 0;
    var total_written: usize = 0;
    while (true) {
        frames += 1;
        try std.testing.expect(frames < 16);
        var writer = Io.Writer.fixed(frame_buffer);
        total_written += try graphics_writer.write(&writer);
        try collected.writer.writeAll(writer.buffered());
        if (!fixture.store.damage) {
            break;
        }
    }

    // The header advertises the compression the payload actually carries.
    try std.testing.expect(std.mem.indexOf(u8, collected.written(), "o=z") != null);
    try std.testing.expect(total_written < pixels.len / 4);
    const payload = try decodeTransmissionPayloads(std.testing.allocator, collected.written());
    defer std.testing.allocator.free(payload);
    const inflated = try inflateExact(std.testing.allocator, payload, pixels.len);
    defer std.testing.allocator.free(inflated);
    try std.testing.expectEqualSlices(u8, pixels, inflated);
    // The transient zlib copy is gone once the transmission closed.
    const entry = fixture.store.images.getPtr(.{
        .pane_id = @enumFromInt(1),
        .image_id = 1,
        .generation = 1,
    }).?;
    try std.testing.expect(entry.compressed == null and entry.compression == null);
    try std.testing.expectEqual(@as(u64, 1), graphics_writer.stats.inline_images);
    try std.testing.expectEqual(@as(u64, 1), graphics_writer.stats.compressed_images);
    try std.testing.expect(graphics_writer.stats.compress_passes >= 1);
}

test "incompressible pixels fall back to a raw transmission" {
    const pixels = try std.testing.allocator.alloc(u8, TransmissionFixture.metadata.byte_len);
    defer std.testing.allocator.free(pixels);
    var prng = std.Random.DefaultPrng.init(11);
    prng.random().bytes(pixels);
    var fixture = try TransmissionFixture.init(pixels);
    defer fixture.deinit();
    fixture.store.host_zlib = true;

    var graphics_writer = fixture.writer(transmission_budget_per_frame * 8);
    const frame_buffer = try std.testing.allocator.alloc(u8, 4 * 1024 * 1024);
    defer std.testing.allocator.free(frame_buffer);
    var collected: Io.Writer.Allocating = .init(std.testing.allocator);
    defer collected.deinit();
    var frames: usize = 0;
    while (true) {
        frames += 1;
        try std.testing.expect(frames < 16);
        var writer = Io.Writer.fixed(frame_buffer);
        _ = try graphics_writer.write(&writer);
        try collected.writer.writeAll(writer.buffered());
        if (!fixture.store.damage) {
            break;
        }
    }

    try std.testing.expect(std.mem.indexOf(u8, collected.written(), "o=z") == null);
    const payload = try decodeTransmissionPayloads(std.testing.allocator, collected.written());
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqualSlices(u8, pixels, payload);
}

test "a compressed transmission resumes across frames" {
    const pixels = try std.testing.allocator.alloc(u8, TransmissionFixture.metadata.byte_len);
    defer std.testing.allocator.free(pixels);
    // Compressible enough to keep the zlib stream, large enough that its
    // encoding still spans several baseline budgets.
    var prng = std.Random.DefaultPrng.init(13);
    for (0..pixels.len / 4) |pixel| {
        const noise = prng.random().int(u8);
        pixels[pixel * 4 + 0] = if (pixel % 3 == 0) noise else 0x20;
        pixels[pixel * 4 + 1] = if (pixel % 3 == 1) noise else 0x20;
        pixels[pixel * 4 + 2] = 0x20;
        pixels[pixel * 4 + 3] = 0xff;
    }
    var fixture = try TransmissionFixture.init(pixels);
    defer fixture.deinit();
    fixture.store.host_zlib = true;

    var graphics_writer = fixture.writer(64 * 1024);
    const frame_buffer = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(frame_buffer);
    var collected: Io.Writer.Allocating = .init(std.testing.allocator);
    defer collected.deinit();
    var frames: usize = 0;
    var resumed = false;
    while (true) {
        frames += 1;
        try std.testing.expect(frames < 64);
        var writer = Io.Writer.fixed(frame_buffer);
        _ = try graphics_writer.write(&writer);
        try collected.writer.writeAll(writer.buffered());
        if (fixture.store.partial != null) {
            try std.testing.expect(fixture.store.partial.?.compressed);
            resumed = true;
        }
        if (!fixture.store.damage) {
            break;
        }
    }

    try std.testing.expect(resumed);
    const payload = try decodeTransmissionPayloads(std.testing.allocator, collected.written());
    defer std.testing.allocator.free(payload);
    const inflated = try inflateExact(std.testing.allocator, payload, pixels.len);
    defer std.testing.allocator.free(inflated);
    try std.testing.expectEqualSlices(u8, pixels, inflated);
}

test "continuous replacements complete and hand off without a blank frame" {
    const pane_id: schema.PaneId = @enumFromInt(1);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 10, .rows = 5 } });

    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const first: graphics.Image = .{
        .key = .{ .image_id = 7, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = first });
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 1,
        .key = first.key,
        .offset = 0,
        .bytes = &.{ 1, 2, 3, 255 },
    });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = .{
            .key = first.key,
            .virtual_id = 1,
            .placement_id = 1,
            .x = 0,
            .y = 0,
        },
    });

    const layout_snapshot = model.layoutSnapshot(.{ .w = 10, .h = 5 });
    var graphics_writer: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = layout_snapshot,
        .cell_width = 10,
        .cell_height = 20,
    };
    var small_buffer: [1024]u8 = undefined;
    var first_writer = Io.Writer.fixed(&small_buffer);
    _ = try graphics_writer.write(&first_writer);

    const placement_key: PlacementIdentity = .{ .pane_id = pane_id, .virtual_id = 1 };
    const placement_id = store.placements.get(placement_key).?.external_id;
    const first_id = store.images.get(identity(pane_id, first.key)).?.external_id;
    try std.testing.expectEqual(
        first_id,
        store.placements.get(placement_key).?.emitted_image_id.?,
    );

    const pixels = try std.testing.allocator.alloc(u8, 256 * 256 * 4);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0x5a);
    const second: graphics.Image = .{
        .key = .{ .image_id = 7, .generation = 2 },
        .format = .rgba,
        .width = 256,
        .height = 256,
        .byte_len = pixels.len,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 2, .image = second });
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 2,
        .key = second.key,
        .offset = 0,
        .bytes = pixels,
    });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 2,
        .placement = .{
            .key = second.key,
            .virtual_id = 1,
            .placement_id = 1,
            .x = 0,
            .y = 0,
        },
    });

    var frame_buffer: [transmission_budget_per_frame + 16 * 1024]u8 = undefined;
    var begin_second = Io.Writer.fixed(&frame_buffer);
    _ = try graphics_writer.write(&begin_second);
    try std.testing.expect(store.partial != null);
    try std.testing.expectEqual(
        first_id,
        store.placements.get(placement_key).?.emitted_image_id.?,
    );

    // A third browser frame arrives before the second has crossed the host
    // terminal. It replaces pending work, but cannot abort the open KGP stream.
    const third: graphics.Image = .{
        .key = .{ .image_id = 7, .generation = 3 },
        .format = .rgba,
        .width = 256,
        .height = 256,
        .byte_len = pixels.len,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 3, .image = third });
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 3,
        .key = third.key,
        .offset = 0,
        .bytes = pixels,
    });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 3,
        .placement = .{
            .key = third.key,
            .virtual_id = 1,
            .placement_id = 1,
            .x = 0,
            .y = 0,
        },
    });
    try store.deleteImage(.{
        .pane_id = pane_id,
        .revision = 3,
        .key = second.key,
    });
    try std.testing.expectEqual(@as(usize, 3), store.images.count());

    const second_id = store.images.get(identity(pane_id, second.key)).?.external_id;
    const third_id = store.images.get(identity(pane_id, third.key)).?.external_id;
    var second_placement_buffer: [64]u8 = undefined;
    const second_placement = try std.fmt.bufPrint(
        &second_placement_buffer,
        "\x1b_Ga=p,i={d},p={d},",
        .{ second_id, placement_id },
    );
    var third_placement_buffer: [64]u8 = undefined;
    const third_placement = try std.fmt.bufPrint(
        &third_placement_buffer,
        "\x1b_Ga=p,i={d},p={d},",
        .{ third_id, placement_id },
    );
    var delete_first_buffer: [64]u8 = undefined;
    const delete_first = try std.fmt.bufPrint(
        &delete_first_buffer,
        "\x1b_Ga=d,d=i,i={d},p={d},q=2\x1b\\",
        .{ first_id, placement_id },
    );
    var delete_second_buffer: [64]u8 = undefined;
    const delete_second = try std.fmt.bufPrint(
        &delete_second_buffer,
        "\x1b_Ga=d,d=i,i={d},p={d},q=2\x1b\\",
        .{ second_id, placement_id },
    );

    var frames: usize = 1;
    var second_handoff = false;
    var third_handoff = false;
    while (store.damage) {
        frames += 1;
        try std.testing.expect(frames < 16);
        var writer = Io.Writer.fixed(&frame_buffer);
        _ = try graphics_writer.write(&writer);
        const output = writer.buffered();
        try std.testing.expect(std.mem.indexOf(u8, output, "\x1b_Gm=0;\x1b\\") == null);
        if (std.mem.indexOf(u8, output, second_placement)) |placement_at| {
            const delete_at = std.mem.indexOf(u8, output, delete_first) orelse
                return error.MissingOldPlacementDelete;
            try std.testing.expect(placement_at < delete_at);
            second_handoff = true;
        }
        if (std.mem.indexOf(u8, output, third_placement)) |placement_at| {
            const delete_at = std.mem.indexOf(u8, output, delete_second) orelse
                return error.MissingOldPlacementDelete;
            try std.testing.expect(placement_at < delete_at);
            third_handoff = true;
        }
        if (!second_handoff) {
            try std.testing.expectEqual(
                first_id,
                store.placements.get(placement_key).?.emitted_image_id.?,
            );
        }
        if (second_handoff and !third_handoff) {
            try std.testing.expectEqual(
                second_id,
                store.placements.get(placement_key).?.emitted_image_id.?,
            );
        }
    }

    try std.testing.expect(second_handoff);
    try std.testing.expect(third_handoff);
    try std.testing.expectEqual(
        third_id,
        store.placements.get(placement_key).?.emitted_image_id.?,
    );
    try std.testing.expectEqual(@as(usize, 1), store.images.count());
    try std.testing.expect(store.images.contains(identity(pane_id, third.key)));
}

test "image and placement deletes encode exactly and clear client state" {
    var output: [256]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    _ = try writeDeleteImage(&writer, 7);
    _ = try writeDeletePlacement(&writer, 7, 11);
    _ = try writeDeleteImageRange(&writer, 1, 9);
    try std.testing.expectEqualStrings(
        "\x1b_Ga=d,d=I,i=7,q=2\x1b\\" ++
            "\x1b_Ga=d,d=i,i=7,p=11,q=2\x1b\\" ++
            "\x1b_Ga=d,d=R,x=1,y=9,q=2\x1b\\",
        writer.buffered(),
    );

    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    const metadata: graphics.Image = .{
        .key = .{ .image_id = 7, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = metadata });
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 1,
        .key = metadata.key,
        .offset = 0,
        .bytes = &.{ 1, 2, 3, 4 },
    });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = .{
            .key = metadata.key,
            .virtual_id = 11,
            .placement_id = 11,
            .x = 0,
            .y = 0,
        },
    });
    try store.deletePlacement(.{
        .pane_id = pane_id,
        .revision = 2,
        .key = metadata.key,
        .virtual_id = 11,
        .placement_id = 11,
    });
    try std.testing.expectEqual(@as(usize, 0), store.placements.count());
    try store.deleteImage(.{ .pane_id = pane_id, .revision = 3, .key = metadata.key });
    try std.testing.expectEqual(@as(usize, 0), store.images.count());
    try std.testing.expectEqual(@as(usize, 0), store.total_bytes);
}

test "client graphics store enforces image and chunk counts" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    for (0..graphics.max_images_per_pane) |index| {
        const image_id: u32 = @intCast(index + 1);
        try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = .{
            .key = .{ .image_id = image_id, .generation = 1 },
            .format = .rgba,
            .width = 1,
            .height = 1,
            .byte_len = 4,
        } });
    }
    try std.testing.expectError(error.GraphicsImageLimitExceeded, store.applyImage(.{
        .pane_id = pane_id,
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 1000, .generation = 1 },
            .format = .rgba,
            .width = 1,
            .height = 1,
            .byte_len = 4,
        },
    }));

    const entry = store.images.getPtr(.{
        .pane_id = pane_id,
        .image_id = 1,
        .generation = 1,
    }).?;
    entry.chunks = graphics.max_chunks_per_image;
    try std.testing.expectError(error.GraphicsChunkLimitExceeded, store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 1,
        .key = .{ .image_id = 1, .generation = 1 },
        .offset = 0,
        .bytes = &.{1},
    }));

    try store.applyImage(.{ .pane_id = pane_id, .revision = 2, .image = .{
        .key = .{ .image_id = 1, .generation = 2 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    } });
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 2,
        .key = .{ .image_id = 1, .generation = 2 },
        .offset = 0,
        .bytes = &.{ 1, 2, 3, 4 },
    });
    try std.testing.expectEqual(graphics.max_images_per_pane, store.images.count());
    try std.testing.expect(store.images.contains(.{
        .pane_id = pane_id,
        .image_id = 1,
        .generation = 2,
    }));
}

test "a completed newer generation replaces incomplete client image storage" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = .{
        .key = .{ .image_id = 7, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    } });
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 1,
        .key = .{ .image_id = 7, .generation = 1 },
        .offset = 0,
        .bytes = &.{1},
    });
    try store.applyImage(.{ .pane_id = pane_id, .revision = 2, .image = .{
        .key = .{ .image_id = 7, .generation = 2 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    } });
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 2,
        .key = .{ .image_id = 7, .generation = 2 },
        .offset = 0,
        .bytes = &.{ 5, 6, 7, 8 },
    });
    try std.testing.expectEqual(@as(usize, 1), store.images.count());
    try std.testing.expectEqual(@as(usize, 4), store.total_bytes);
    try std.testing.expect(store.images.contains(.{
        .pane_id = pane_id,
        .image_id = 7,
        .generation = 2,
    }));
}

test "a flood of stale generations of one image cannot overflow eviction" {
    // Regression: `removeOtherGenerations` collected obsolete keys into a
    // fixed `[max_images_per_pane]` stack array, but retransmissions of one
    // image id bypass the logical-count limit, so far more than that many
    // generations could coexist and completing one wrote past the array.
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    const generations = graphics.max_images_per_pane + 8;
    var generation: u64 = 1;
    while (generation <= generations) : (generation += 1) {
        try store.applyImage(.{ .pane_id = pane_id, .revision = generation, .image = .{
            .key = .{ .image_id = 7, .generation = generation },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        } });
    }
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = generations,
        .key = .{ .image_id = 7, .generation = generations },
        .offset = 0,
        .bytes = &.{ 1, 2, 3 },
    });
    try std.testing.expectEqual(@as(usize, 1), store.images.count());
    try std.testing.expect(store.images.contains(.{
        .pane_id = pane_id,
        .image_id = 7,
        .generation = generations,
    }));
    try std.testing.expectEqual(@as(usize, 3), store.total_bytes);
}

test "the store tracks panes for a whole client, not one tab" {
    // Regression: `revisions` and `hidden_panes` were fixed arrays sized
    // `schema.max_panes_per_tab`, but one store serves every tab of the
    // client, so the 65th pane with graphics - or the 65th hidden pane -
    // returned ClientPaneLimitExceeded and the error killed the client.
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const panes = schema.max_panes_per_tab + 8;
    var index: usize = 0;
    while (index < panes) : (index += 1) {
        const pane_id: schema.PaneId = @enumFromInt(index + 1);
        try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        } });
        try store.setPaneVisible(pane_id, false);
        try std.testing.expect(!store.paneVisible(pane_id));
    }
    try std.testing.expectEqual(@as(usize, panes), store.images.count());
}

test "pane usage counters match a full recount" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const first_pane: schema.PaneId = @enumFromInt(1);
    const second_pane: schema.PaneId = @enumFromInt(2);
    const metadata: graphics.Image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    for ([_]schema.PaneId{ first_pane, second_pane }) |pane_id| {
        try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = metadata });
        try store.applyChunk(.{
            .pane_id = pane_id,
            .revision = 1,
            .key = metadata.key,
            .offset = 0,
            .bytes = &.{ 1, 2, 3, 4 },
        });
        try store.applyPlacement(.{ .pane_id = pane_id, .revision = 1, .placement = .{
            .key = metadata.key,
            .virtual_id = 1,
            .placement_id = 1,
            .x = 0,
            .y = 0,
        } });
    }
    try store.deletePlacement(.{
        .pane_id = second_pane,
        .revision = 2,
        .key = metadata.key,
        .virtual_id = 1,
        .placement_id = 1,
    });
    try store.deleteImage(.{ .pane_id = second_pane, .revision = 3, .key = metadata.key });

    for ([_]schema.PaneId{ first_pane, second_pane }) |pane_id| {
        var counted: Store.PaneUsage = .{};
        var images = store.images.iterator();
        while (images.next()) |entry| {
            if (entry.key_ptr.pane_id != pane_id) {
                continue;
            }
            counted.count += 1;
            counted.bytes += entry.value_ptr.pixels.len;
        }
        var placements = store.placements.iterator();
        while (placements.next()) |entry| {
            if (entry.key_ptr.pane_id == pane_id) {
                counted.placements += 1;
            }
        }
        const tracked: Store.PaneUsage = store.usage.get(pane_id) orelse .{};
        try std.testing.expectEqual(counted.count, tracked.count);
        try std.testing.expectEqual(counted.bytes, tracked.bytes);
        try std.testing.expectEqual(counted.placements, tracked.placements);
        try std.testing.expectEqual(counted.count != 0, store.hasPaneGraphics(pane_id));
    }
    const credit = store.peekCredit().?;
    try std.testing.expectEqual(second_pane, credit.pane_id);
    try std.testing.expectEqual(@as(usize, 4), credit.bytes);
    store.consumeCredit(credit);
    // A pane with nothing left and no unreturned credit holds no usage entry.
    try std.testing.expect(!store.usage.contains(second_pane));
}

test "snapshot replacement returns client image credit" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    const image: graphics.Image = .{
        .key = .{ .image_id = 7, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = image });
    try store.applySnapshot(.{ .pane_id = pane_id, .revision = 2, .phase = .begin });

    const credit = store.peekCredit().?;
    try std.testing.expectEqual(pane_id, credit.pane_id);
    try std.testing.expectEqual(@as(usize, 4), credit.bytes);
    store.consumeCredit(credit);
    try std.testing.expect(store.peekCredit() == null);

    // Detaching destroys client state; there is no runtime attachment left
    // to receive credit for those bytes.
    try store.applyImage(.{ .pane_id = pane_id, .revision = 2, .image = image });
    store.clearPane(pane_id);
    try std.testing.expect(store.peekCredit() == null);
}

test "shared client pixels have a bounded POSIX lifetime" {
    if (comptime !supportsSharedMemory()) {
        return error.SkipZigTest;
    }

    var store = Store.initSharedMemory(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    const image: graphics.Image = .{
        .key = .{ .image_id = 7, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = image });
    const shared = store.images.get(identity(pane_id, image.key)).?.shared.?;
    const fd = std.c.shm_open(
        shared.sliceZ(),
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })),
        @as(u16, 0),
    );
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(fd));
    _ = std.c.close(fd);

    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 1,
        .key = image.key,
        .offset = 0,
        .bytes = &.{ 1, 2, 3, 255 },
    });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = .{
            .key = image.key,
            .virtual_id = 1,
            .placement_id = 1,
            .x = 0,
            .y = 0,
        },
    });
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = pane_id, .location = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 10, .rows = 5 } });
    var graphics_writer: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = model.layoutSnapshot(.{ .w = 10, .h = 5 }),
        .cell_width = 10,
        .cell_height = 20,
    };
    var output: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    _ = try graphics_writer.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "t=s") != null);
    try std.testing.expect(store.partial == null);

    try store.deletePlacement(.{
        .pane_id = pane_id,
        .revision = 2,
        .key = image.key,
        .virtual_id = 1,
        .placement_id = 1,
    });
    try store.deleteImage(.{ .pane_id = pane_id, .revision = 3, .key = image.key });
    try std.testing.expectEqual(@as(usize, 1), store.images.count());
    try std.testing.expect(store.peekCredit() == null);
    var waiting_output: [1024]u8 = undefined;
    var waiting_writer = Io.Writer.fixed(&waiting_output);
    _ = try graphics_writer.write(&waiting_writer);
    try std.testing.expect(store.damage);

    // Ghostty unlinks the object after copying it. Until then the client keeps
    // the mapping resident and cannot return its memory credit to the runtime.
    try std.testing.expectEqual(@as(c_int, 0), std.c.shm_unlink(shared.sliceZ()));
    var released_output: [1024]u8 = undefined;
    var released_writer = Io.Writer.fixed(&released_output);
    _ = try graphics_writer.write(&released_writer);
    try std.testing.expectEqual(@as(usize, 0), store.images.count());
    const credit = store.peekCredit().?;
    try std.testing.expectEqual(@as(usize, 4), credit.bytes);
    store.consumeCredit(credit);
    const missing = std.c.shm_open(
        shared.sliceZ(),
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })),
        @as(u16, 0),
    );
    try std.testing.expectEqual(std.posix.E.NOENT, std.posix.errno(missing));
}

test "shared transmission sends only a KGP resource name" {
    var output: [256]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    const written = try writeSharedTransmission(&writer, .{
        .external_id = 7,
        .image = .{
            .key = .{ .image_id = 7, .generation = 1 },
            .format = .rgba,
            .width = 1,
            .height = 1,
            .byte_len = 4,
        },
        .name = "/telar-test",
    });
    try std.testing.expectEqualStrings(
        "\x1b_Ga=t,f=32,s=1,v=1,t=s,i=7,q=0;L3RlbGFyLXRlc3Q=\x1b\\",
        writer.buffered(),
    );
    try std.testing.expectEqual(writer.buffered().len, written);
}

test "a host acknowledgement retires a replaced shared image without probing" {
    if (comptime !supportsSharedMemory()) {
        return error.SkipZigTest;
    }

    var store = Store.initSharedMemory(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    const source = [_]u8{ 1, 2, 3, 255 };
    var first_name_buffer: [64]u8 = undefined;
    const first_name = try graphics.ShmName.init(try std.fmt.bufPrint(&first_name_buffer, "/tlrtest-ack1-{d}", .{std.c.getpid()}));
    _ = std.c.shm_unlink(first_name.sliceZ());
    try testCreateSharedObject(first_name.sliceZ(), &source);
    defer _ = std.c.shm_unlink(first_name.sliceZ());
    var second_name_buffer: [64]u8 = undefined;
    const second_name = try graphics.ShmName.init(try std.fmt.bufPrint(&second_name_buffer, "/tlrtest-ack2-{d}", .{std.c.getpid()}));
    _ = std.c.shm_unlink(second_name.sliceZ());
    try testCreateSharedObject(second_name.sliceZ(), &source);
    defer _ = std.c.shm_unlink(second_name.sliceZ());

    const first: graphics.Image = .{ .key = .{ .image_id = 7, .generation = 1 }, .format = .rgba, .width = 1, .height = 1, .byte_len = 4 };
    try store.applySharedImage(.{ .pane_id = pane_id, .revision = 1, .image = first, .name = first_name });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = .{ .key = first.key, .virtual_id = 1, .placement_id = 1, .x = 0, .y = 0 },
    });
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = pane_id, .location = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 10, .rows = 5 } });
    var graphics_writer: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = model.layoutSnapshot(.{ .w = 10, .h = 5 }),
        .cell_width = 10,
        .cell_height = 20,
    };
    var output: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    _ = try graphics_writer.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "q=0;") != null);
    const first_external = store.images.get(identity(pane_id, first.key)).?.external_id;

    // A reply for an id the store does not hold changes nothing.
    try std.testing.expect(!store.noteHostReply(first_external + 1000, true));
    try std.testing.expect(store.noteHostReply(first_external, true));
    try std.testing.expect(store.images.get(identity(pane_id, first.key)).?.host_acked);

    // The object still exists: without the reply a probe would keep the
    // replaced generation alive. With it, the replacement retires it.
    const second: graphics.Image = .{ .key = .{ .image_id = 7, .generation = 2 }, .format = .rgba, .width = 1, .height = 1, .byte_len = 4 };
    try store.applySharedImage(.{ .pane_id = pane_id, .revision = 2, .image = second, .name = second_name });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 2,
        .placement = .{ .key = second.key, .virtual_id = 1, .placement_id = 1, .x = 0, .y = 0 },
    });
    var second_output: [1024]u8 = undefined;
    var second_writer = Io.Writer.fixed(&second_output);
    _ = try graphics_writer.write(&second_writer);
    try std.testing.expectEqual(@as(usize, 1), store.images.count());
    try std.testing.expect(store.images.get(identity(pane_id, second.key)) != null);
    const credit = store.peekCredit() orelse return error.CreditNotReleased;
    try std.testing.expectEqual(@as(usize, 4), credit.bytes);
    store.consumeCredit(credit);
}

test "a host error reply reclaims the shared name and retransmits inline" {
    if (comptime !supportsSharedMemory()) {
        return error.SkipZigTest;
    }

    var store = Store.initSharedMemory(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    const source = [_]u8{ 1, 2, 3, 255 };
    var name_buffer: [64]u8 = undefined;
    const name = try graphics.ShmName.init(try std.fmt.bufPrint(&name_buffer, "/tlrtest-nack-{d}", .{std.c.getpid()}));
    _ = std.c.shm_unlink(name.sliceZ());
    try testCreateSharedObject(name.sliceZ(), &source);
    defer _ = std.c.shm_unlink(name.sliceZ());
    const image: graphics.Image = .{ .key = .{ .image_id = 7, .generation = 1 }, .format = .rgba, .width = 1, .height = 1, .byte_len = 4 };
    try store.applySharedImage(.{ .pane_id = pane_id, .revision = 1, .image = image, .name = name });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = .{ .key = image.key, .virtual_id = 1, .placement_id = 1, .x = 0, .y = 0 },
    });
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = pane_id, .location = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 10, .rows = 5 } });
    var graphics_writer: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = model.layoutSnapshot(.{ .w = 10, .h = 5 }),
        .cell_width = 10,
        .cell_height = 20,
    };
    var output: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    _ = try graphics_writer.write(&writer);
    const external = store.images.get(identity(pane_id, image.key)).?.external_id;

    try std.testing.expect(store.noteHostReply(external, false));

    try std.testing.expect(store.damage);
    var retry: [4096]u8 = undefined;
    var retry_writer = Io.Writer.fixed(&retry);
    _ = try graphics_writer.write(&retry_writer);
    try std.testing.expect(std.mem.indexOf(u8, retry_writer.buffered(), "t=d") != null);
    try std.testing.expect(std.mem.indexOf(u8, retry_writer.buffered(), "t=s") == null);
    try std.testing.expectEqual(@as(u64, 1), graphics_writer.stats.inline_images);
}

test "graphics revisions ignore stale deltas and validate snapshots" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    const metadata: graphics.Image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 5, .image = metadata });
    try std.testing.expectEqual(@as(u64, 1), store.ingressVersion());
    try store.deleteImage(.{ .pane_id = pane_id, .revision = 4, .key = metadata.key });
    try std.testing.expect(store.images.contains(identity(pane_id, metadata.key)));
    try std.testing.expectEqual(@as(u64, 1), store.ingressVersion());

    try store.applySnapshot(.{ .pane_id = pane_id, .revision = 8, .phase = .begin });
    try std.testing.expectEqual(@as(u64, 2), store.ingressVersion());
    try std.testing.expectError(error.GraphicsResyncRequired, store.applyImage(.{
        .pane_id = pane_id,
        .revision = 9,
        .image = metadata,
    }));
    try std.testing.expectEqual(@as(u64, 2), store.ingressVersion());
    try store.applySnapshot(.{ .pane_id = pane_id, .revision = 10, .phase = .begin });
    try store.applySnapshot(.{ .pane_id = pane_id, .revision = 10, .phase = .end });
    try std.testing.expectEqual(@as(u64, 4), store.ingressVersion());
}

fn testCreateSharedObject(name: [:0]const u8, pixels: []const u8) !void {
    const fd = std.c.shm_open(
        name,
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true })),
        @as(u16, 0o600),
    );
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(fd));
    defer _ = std.c.close(fd);
    try std.testing.expectEqual(@as(c_int, 0), std.c.ftruncate(fd, @intCast(pixels.len)));
    const map = try std.posix.mmap(
        null,
        pixels.len,
        .{ .READ = true, .WRITE = true },
        std.c.MAP{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer std.posix.munmap(map);
    @memcpy(map[0..pixels.len], pixels);
}

test "an undersized runtime shared object is rejected and unlinked" {
    if (comptime !supportsSharedMemory()) {
        return error.SkipZigTest;
    }

    var store = Store.initSharedMemory(std.testing.allocator);
    defer store.deinit();
    var name_buffer: [64]u8 = undefined;
    const name = try graphics.ShmName.init(try std.fmt.bufPrint(&name_buffer, "/tlrtest-short-{d}", .{std.c.getpid()}));
    _ = std.c.shm_unlink(name.sliceZ());
    defer _ = std.c.shm_unlink(name.sliceZ());
    try testCreateSharedObject(name.sliceZ(), "RGBA");
    // Exceed Darwin's page-rounded shared object size as well as Linux's size.
    const height = std.heap.pageSize() / 512 + 1;

    try std.testing.expectError(error.GraphicsSharedMappingFailed, store.applySharedImage(.{
        .pane_id = @enumFromInt(1),
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 7, .generation = 1 },
            .format = .rgba,
            .width = 128,
            .height = @intCast(height),
            .byte_len = 512 * height,
        },
        .name = name,
    }));
    try std.testing.expectEqual(@as(usize, 0), store.images.count());
    try std.testing.expectEqual(@as(c_int, -1), std.c.shm_unlink(name.sliceZ()));
    try std.testing.expectEqual(std.posix.E.NOENT, std.posix.errno(-1));
}

test "a runtime-named image maps without copying and hands the host its name" {
    if (comptime !supportsSharedMemory()) {
        return error.SkipZigTest;
    }

    var store = Store.initSharedMemory(std.testing.allocator);
    defer store.deinit();
    var name_buffer: [64]u8 = undefined;
    const name = try graphics.ShmName.init(try std.fmt.bufPrint(
        &name_buffer,
        "/tlrtest-map-{d}",
        .{std.c.getpid()},
    ));
    _ = std.c.shm_unlink(name.sliceZ());
    const source = [_]u8{ 1, 2, 3, 255 };
    try testCreateSharedObject(name.sliceZ(), &source);

    const pane_id: schema.PaneId = @enumFromInt(1);
    const image: graphics.Image = .{
        .key = .{ .image_id = 7, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applySharedImage(.{
        .pane_id = pane_id,
        .revision = 1,
        .image = image,
        .name = name,
    });
    const entry = store.images.get(identity(pane_id, image.key)).?;
    try std.testing.expectEqual(@as(usize, 4), entry.received);
    try std.testing.expectEqualSlices(u8, &source, entry.pixels);

    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = .{
            .key = image.key,
            .virtual_id = 1,
            .placement_id = 1,
            .x = 0,
            .y = 0,
        },
    });
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = pane_id, .location = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 10, .rows = 5 } });
    var graphics_writer: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = model.layoutSnapshot(.{ .w = 10, .h = 5 }),
        .cell_width = 10,
        .cell_height = 20,
    };
    var output: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    _ = try graphics_writer.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "t=s") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "t=d") == null);

    // Ghostty consumes and unlinks; retiring then releases the credit.
    try std.testing.expectEqual(@as(c_int, 0), std.c.shm_unlink(name.sliceZ()));
    try store.deletePlacement(.{
        .pane_id = pane_id,
        .revision = 2,
        .key = image.key,
        .virtual_id = 1,
        .placement_id = 1,
    });
    try store.deleteImage(.{ .pane_id = pane_id, .revision = 3, .key = image.key });
    var released_output: [1024]u8 = undefined;
    var released_writer = Io.Writer.fixed(&released_output);
    _ = try graphics_writer.write(&released_writer);
    try std.testing.expectEqual(@as(usize, 0), store.images.count());
    const credit = store.peekCredit().?;
    try std.testing.expectEqual(@as(usize, 4), credit.bytes);
    store.consumeCredit(credit);
}

test "a control pass hands the host shared names and placements without pixel streams" {
    if (comptime !supportsSharedMemory()) {
        return error.SkipZigTest;
    }

    var store = Store.initSharedMemory(std.testing.allocator);
    defer store.deinit();
    var name_buffer: [64]u8 = undefined;
    const name = try graphics.ShmName.init(try std.fmt.bufPrint(
        &name_buffer,
        "/tlrtest-control-{d}",
        .{std.c.getpid()},
    ));
    _ = std.c.shm_unlink(name.sliceZ());
    const source = [_]u8{ 1, 2, 3, 255 };
    try testCreateSharedObject(name.sliceZ(), &source);
    defer _ = std.c.shm_unlink(name.sliceZ());

    const pane_id: schema.PaneId = @enumFromInt(1);
    const shared_image: graphics.Image = .{
        .key = .{ .image_id = 7, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applySharedImage(.{ .pane_id = pane_id, .revision = 1, .image = shared_image, .name = name });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = .{ .key = shared_image.key, .virtual_id = 1, .placement_id = 1, .x = 0, .y = 0 },
    });
    const inline_image: graphics.Image = .{
        .key = .{ .image_id = 8, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = inline_image });
    try store.applyChunk(.{ .pane_id = pane_id, .revision = 1, .key = inline_image.key, .offset = 0, .bytes = &source });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = .{ .key = inline_image.key, .virtual_id = 2, .placement_id = 2, .x = 1, .y = 0 },
    });
    // A shared-memory client also names its own images; a host that lost
    // one is served inline, which is the bulk pass's job.
    store.images.getPtr(identity(pane_id, inline_image.key)).?.force_direct = true;
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = pane_id, .location = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 10, .rows = 5 } });
    const layout_snapshot = model.layoutSnapshot(.{ .w = 10, .h = 5 });

    var control: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = layout_snapshot,
        .cell_width = 10,
        .cell_height = 20,
        .mode = .control,
    };
    var control_output: [1024]u8 = undefined;
    var control_writer = Io.Writer.fixed(&control_output);
    _ = try control.write(&control_writer);
    const control_bytes = control_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, control_bytes, "t=s") != null);
    try std.testing.expect(std.mem.indexOf(u8, control_bytes, "a=p,") != null);
    try std.testing.expect(std.mem.indexOf(u8, control_bytes, "t=d") == null);
    try std.testing.expectEqual(@as(u64, 1), control.stats.shared_images);
    try std.testing.expectEqual(@as(u64, 0), control.stats.inline_images);
    // The inline image keeps its damage for the bulk pass.
    try std.testing.expect(store.damage);

    var bulk: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = layout_snapshot,
        .cell_width = 10,
        .cell_height = 20,
    };
    var bulk_output: [1024]u8 = undefined;
    var bulk_writer = Io.Writer.fixed(&bulk_output);
    _ = try bulk.write(&bulk_writer);
    const bulk_bytes = bulk_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, bulk_bytes, "t=d") != null);
    try std.testing.expect(std.mem.indexOf(u8, bulk_bytes, "t=s") == null);
    try std.testing.expectEqual(@as(u64, 1), bulk.stats.inline_images);
    try std.testing.expect(!store.damage);
}

test "a control pass emits nothing while a chunked transfer is open" {
    const pane_id: schema.PaneId = @enumFromInt(1);
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = pane_id, .location = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 10, .rows = 5 } });
    const layout_snapshot = model.layoutSnapshot(.{ .w = 10, .h = 5 });

    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const pixels = try std.testing.allocator.alloc(u8, 64 * 64 * 4);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0x5a);
    const image: graphics.Image = .{
        .key = .{ .image_id = 7, .generation = 1 },
        .format = .rgba,
        .width = 64,
        .height = 64,
        .byte_len = pixels.len,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = image });
    try store.applyChunk(.{ .pane_id = pane_id, .revision = 1, .key = image.key, .offset = 0, .bytes = pixels });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = .{ .key = image.key, .virtual_id = 1, .placement_id = 1, .x = 0, .y = 0 },
    });

    var bulk: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = layout_snapshot,
        .cell_width = 10,
        .cell_height = 20,
        .budget = 4096,
    };
    var bulk_output: [8192]u8 = undefined;
    var bulk_writer = Io.Writer.fixed(&bulk_output);
    _ = try bulk.write(&bulk_writer);
    try std.testing.expect(store.partial != null);

    var control: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = layout_snapshot,
        .cell_width = 10,
        .cell_height = 20,
        .mode = .control,
    };
    var control_output: [1024]u8 = undefined;
    var control_writer = Io.Writer.fixed(&control_output);
    try std.testing.expectEqual(@as(usize, 0), try control.write(&control_writer));
    try std.testing.expect(store.partial != null);
    try std.testing.expect(store.damage);
}

test "a host that never consumes shared names loses them and gets pixels inline" {
    if (comptime !supportsSharedMemory()) {
        return error.SkipZigTest;
    }

    var store = Store.initSharedMemory(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = pane_id, .location = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 10, .rows = 5 } });
    var graphics_writer: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = model.layoutSnapshot(.{ .w = 10, .h = 5 }),
        .cell_width = 10,
        .cell_height = 20,
    };

    const source = [_]u8{ 9, 9, 9, 255 };
    for ([_][]const u8{ "a1", "a2" }, 1..) |suffix, generation| {
        var name_buffer: [64]u8 = undefined;
        const name = try graphics.ShmName.init(try std.fmt.bufPrint(
            &name_buffer,
            "/tlrtest-exp-{s}-{d}",
            .{ suffix, std.c.getpid() },
        ));
        _ = std.c.shm_unlink(name.sliceZ());
        try testCreateSharedObject(name.sliceZ(), &source);
        try store.applySharedImage(.{
            .pane_id = pane_id,
            .revision = generation,
            .image = .{
                .key = .{ .image_id = 7, .generation = generation },
                .format = .rgba,
                .width = 1,
                .height = 1,
                .byte_len = 4,
            },
            .name = name,
        });
        var output: [4096]u8 = undefined;
        var writer = Io.Writer.fixed(&output);
        _ = try graphics_writer.write(&writer);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "t=s") != null);

        // The host never opens the object. Past the deadline the client
        // reclaims it and retransmits the pixels inline from the mapping.
        store.pass_counter +%= shared_consume_deadline_passes;
        var retry_output: [4096]u8 = undefined;
        var retry_writer = Io.Writer.fixed(&retry_output);
        _ = try graphics_writer.write(&retry_writer);
        try std.testing.expect(std.mem.indexOf(u8, retry_writer.buffered(), "t=d") != null);
        const missing = std.c.shm_open(
            name.sliceZ(),
            @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })),
            @as(u16, 0),
        );
        try std.testing.expectEqual(std.posix.E.NOENT, std.posix.errno(missing));
    }

    // Two expiries prove the host cannot consume names at all; the session
    // stops offering them.
    try std.testing.expect(!store.shared_memory);
}

test "invalidating many placements queues no deletes and keeps shared transport" {
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    const panes = [_]schema.PaneId{ @enumFromInt(1), @enumFromInt(2), @enumFromInt(3) };
    try model.addRoot(.{ .pane_id = panes[0], .location = location, .size = .{ .cols = 40, .rows = 40 } });
    try model.split(.{ .existing_pane = panes[0], .new_pane = panes[1], .location = location, .axis = .horizontal, .area = .{ .w = 120, .h = 40 } });
    try model.split(.{ .existing_pane = panes[1], .new_pane = panes[2], .location = location, .axis = .horizontal, .area = .{ .w = 120, .h = 40 } });
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const metadata: graphics.Image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    // More placements in total than the delete ring holds, spread so no
    // pane exceeds its own limit.
    const per_pane = store.delete_queue.len / 2 - 8;
    for (panes) |pane_id| {
        try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = metadata });
        try store.applyChunk(.{ .pane_id = pane_id, .revision = 1, .key = metadata.key, .offset = 0, .bytes = &.{ 1, 2, 3, 255 } });
        var virtual_id: u32 = 1;
        while (virtual_id <= per_pane) : (virtual_id += 1) {
            try store.applyPlacement(.{
                .pane_id = pane_id,
                .revision = 1,
                .placement = .{
                    .key = metadata.key,
                    .virtual_id = virtual_id,
                    .placement_id = virtual_id,
                    .x = @intCast(virtual_id % 16),
                    .y = @intCast(virtual_id / 16),
                    .columns = 1,
                    .rows = 1,
                },
            });
        }
    }
    const layout_snapshot = model.layoutSnapshot(.{ .w = 120, .h = 40 });
    var graphics_writer: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = layout_snapshot,
        .cell_width = 10,
        .cell_height = 20,
    };
    var first_bytes: [1 << 20]u8 = undefined;
    var first_writer = Io.Writer.fixed(&first_bytes);
    _ = try graphics_writer.write(&first_writer);
    while (store.damage) {
        first_writer = Io.Writer.fixed(&first_bytes);
        _ = try graphics_writer.write(&first_writer);
    }

    store.invalidatePlacements();
    try std.testing.expect(!store.delete_overflow);
    try std.testing.expectEqual(@as(usize, 0), store.delete_len);
    var resize_bytes: [1 << 20]u8 = undefined;
    var resize_writer = Io.Writer.fixed(&resize_bytes);
    _ = try graphics_writer.write(&resize_writer);
    try std.testing.expect(std.mem.indexOf(u8, resize_writer.buffered(), "a=d") == null);
    try std.testing.expect(std.mem.indexOf(u8, resize_writer.buffered(), "a=t") == null);
    try std.testing.expectEqual(per_pane * panes.len, std.mem.count(u8, resize_writer.buffered(), "a=p"));
    for (panes) |pane_id| {
        try std.testing.expect(!store.images.get(identity(pane_id, metadata.key)).?.force_direct);
    }
}
