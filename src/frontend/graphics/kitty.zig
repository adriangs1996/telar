//! Client-side Kitty graphics resource storage and host-protocol emission.

const std = @import("std");
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
pub const transmission_budget_per_frame: usize = 256 * 1024;

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
const Compression = struct {
    allocating: Io.Writer.Allocating,
    window: [std.compress.flate.max_window_len]u8,
    compress: std.compress.flate.Compress,
    offset: usize,
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

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn initSharedMemory(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa, .shared_memory = supportsSharedMemory() };
    }

    pub fn deinit(store: *Store) void {
        var images = store.images.iterator();
        while (images.next()) |entry| store.freePixels(entry.value_ptr);
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
            state.allocating.deinit();
            store.gpa.destroy(state);
            entry.compression = null;
        }
        if (entry.compressed) |bytes| {
            store.gpa.free(bytes);
            entry.compressed = null;
        }
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
        var stat: std.c.Stat = undefined;
        if (std.c.fstat(fd, &stat) != 0) {
            return error.SharedMemoryUnavailable;
        }
        if (stat.size < 0 or @as(u64, @intCast(stat.size)) < byte_len) {
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
        image.retire_pending = true;
        store.removePlacementsForImage(pane_id, key);
        store.collectRetired(pane_id, key.image_id);
        store.damage = true;

        return true;
    }

    fn removeImageData(store: *Store, key: ImageIdentity) void {
        const removed = store.images.fetchRemove(key) orelse return;
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

    pub fn invalidatePlacements(store: *Store) void {
        var iterator = store.placements.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.emitted_image_id) |image_id| {
                store.queueDelete(.{ .placement = .{
                    .image_id = image_id,
                    .placement_id = entry.value_ptr.external_id,
                } });
            }
            entry.value_ptr.emitted_image_id = null;
            entry.value_ptr.dirty = true;
        }
        store.collectRetired(null, null);
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
            entry.value_ptr.retire_pending = true;
        }
        store.collectRetired(pane_id, current.image_id);
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
        self.store.pass_counter +%= 1;
        self.store.clock_ns = self.now_ns;
        self.store.expireSharedTransmissions();
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
                entry.transmitted = true;
                self.stats.inline_images += 1;
                self.stats.compressed_images += @intFromBool(partial.compressed);
                self.store.freeCompression(entry);
                self.store.partial = null;
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
            self.store.delete_head = 0;
            self.store.delete_len = 0;
            self.store.delete_overflow = false;
            var reset_images = self.store.images.iterator();
            while (reset_images.next()) |entry| {
                entry.value_ptr.transmitted = false;
                entry.value_ptr.force_direct = true;
            }
            var reset_placements = self.store.placements.iterator();
            while (reset_placements.next()) |entry| {
                entry.value_ptr.emitted_image_id = null;
                entry.value_ptr.dirty = true;
            }
            self.store.collectRetired(null, null);
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
                    image.transmitted = true;
                    image.emitted_shared = true;
                    image.transmitted_pass = self.store.pass_counter;
                    image.transmitted_ns = self.now_ns;
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
            image.transmitted = true;
            self.stats.inline_images += 1;
            self.stats.compressed_images += @intFromBool(compressed);
            self.store.freeCompression(image);
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

pub const OutputPlacement = struct {
    column: u32,
    row: u32,
    offset_x: u32,
    offset_y: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    columns: u32,
    rows: u32,
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

/// Formats once into a bounded scratch buffer, writes the result, and
/// returns its length. Every control sequence here fits with room to spare;
/// the alternative, `std.fmt.count` after `print`, formats everything twice.
fn printCounted(writer: *Io.Writer, comptime format: []const u8, args: anytype) Io.Writer.Error!usize {
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch unreachable;
    try writer.writeAll(text);
    return text.len;
}

pub const ChunkProgress = struct { written: usize, offset: usize };

pub const TransmissionChunks = struct {
    external_id: u32,
    image: graphics.Image,
    pixels: []const u8,
    start_offset: usize,
    budget: usize,
    compressed: bool,
};

pub const PngTransmissionChunks = struct {
    external_id: u32,
    png: []const u8,
    start_offset: usize,
    budget: usize,
};

pub const Transmission = struct {
    external_id: u32,
    image: graphics.Image,
    pixels: []const u8,
};

pub const SharedTransmission = struct {
    external_id: u32,
    image: graphics.Image,
    name: []const u8,
};

/// Emits transmission chunks for `pixels` starting at byte `start_offset`,
/// spending roughly `budget` encoded bytes. Always makes progress: at least
/// one chunk goes out even under a zero budget, so a caller looping on the
/// offset cannot stall. `offset == pixels.len` in the result means the final
/// `m=0` chunk went out and the transfer is closed.
/// For example: `try writeTransmissionChunks(writer, transmission)`.
pub fn writeTransmissionChunks(writer: *Io.Writer, transmission: TransmissionChunks) Io.Writer.Error!ChunkProgress {
    const Encoder = std.base64.standard.Encoder;
    const raw_chunk_size = 3072;
    var encoded: [4096]u8 = undefined;
    var offset = transmission.start_offset;
    var written: usize = 0;
    while (offset < transmission.pixels.len) {
        if (written != 0 and written >= transmission.budget) {
            break;
        }
        const take = @min(raw_chunk_size, transmission.pixels.len - offset);
        const payload = Encoder.encode(encoded[0..Encoder.calcSize(take)], transmission.pixels[offset..][0..take]);
        const more = offset + take < transmission.pixels.len;
        if (offset == 0) {
            written += try printCounted(writer, "\x1b_Ga=t,f={d},s={d},v={d},t=d,i={d},q=2{s},m={d};", .{
                @intFromEnum(transmission.image.format), transmission.image.width,                    transmission.image.height,
                transmission.external_id,                if (transmission.compressed) ",o=z" else "", @intFromBool(more),
            });
        } else {
            written += try printCounted(writer, "\x1b_Gm={d};", .{@intFromBool(more)});
        }
        try writer.writeAll(payload);
        try writer.writeAll("\x1b\\");
        written += payload.len + 2;
        offset += take;
    }
    return .{ .written = written, .offset = offset };
}

/// Emits an already encoded PNG using Kitty's direct-data transport. PNG is
/// the one encoded format the protocol standardizes (`f=100`), so local
/// clipboard previews can stay compressed in client memory and on the wire.
/// For example: `try writePngTransmissionChunks(writer, transmission)`.
pub fn writePngTransmissionChunks(writer: *Io.Writer, transmission: PngTransmissionChunks) Io.Writer.Error!ChunkProgress {
    const Encoder = std.base64.standard.Encoder;
    const raw_chunk_size = 3072;
    var encoded: [4096]u8 = undefined;
    var offset = transmission.start_offset;
    var written: usize = 0;
    while (offset < transmission.png.len) {
        if (written != 0 and written >= transmission.budget) {
            break;
        }
        const take = @min(raw_chunk_size, transmission.png.len - offset);
        const payload = Encoder.encode(encoded[0..Encoder.calcSize(take)], transmission.png[offset..][0..take]);
        const more = offset + take < transmission.png.len;
        if (offset == 0) {
            written += try printCounted(
                writer,
                "\x1b_Ga=t,f=100,t=d,i={d},q=2,m={d};",
                .{ transmission.external_id, @intFromBool(more) },
            );
        } else {
            written += try printCounted(writer, "\x1b_Gm={d};", .{@intFromBool(more)});
        }
        try writer.writeAll(payload);
        try writer.writeAll("\x1b\\");
        written += payload.len + 2;
        offset += take;
    }
    return .{ .written = written, .offset = offset };
}

/// Emits one complete raw image transmission.
/// For example: `try writeTransmission(writer, transmission)`.
pub fn writeTransmission(writer: *Io.Writer, transmission: Transmission) Io.Writer.Error!usize {
    const progress = try writeTransmissionChunks(writer, .{
        .external_id = transmission.external_id,
        .image = transmission.image,
        .pixels = transmission.pixels,
        .start_offset = 0,
        .budget = std.math.maxInt(usize),
        .compressed = false,
    });
    return progress.written;
}

/// Hands the host a shared object's name. Unlike every other pane escape it
/// asks for a reply (`q=0`): the host's `OK` is the consume signal that
/// retires the image, and an error reclaims the name at once.
/// For example: `try writeSharedTransmission(writer, transmission)`.
pub fn writeSharedTransmission(writer: *Io.Writer, transmission: SharedTransmission) Io.Writer.Error!usize {
    const Encoder = std.base64.standard.Encoder;
    var encoded: [128]u8 = undefined;
    const payload = Encoder.encode(encoded[0..Encoder.calcSize(transmission.name.len)], transmission.name);
    var written = try printCounted(
        writer,
        "\x1b_Ga=t,f={d},s={d},v={d},t=s,i={d},q=0;",
        .{ @intFromEnum(transmission.image.format), transmission.image.width, transmission.image.height, transmission.external_id },
    );
    try writer.writeAll(payload);
    try writer.writeAll("\x1b\\");
    written += payload.len + 2;
    return written;
}

/// Closes an interrupted chunked transfer with an empty final chunk. The
/// terminal discards the short payload; q=2 on the header keeps it silent.
pub fn writeTransmissionAbort(writer: *Io.Writer) Io.Writer.Error!usize {
    const closing = "\x1b_Gm=0;\x1b\\";
    try writer.writeAll(closing);
    return closing.len;
}

pub const PlacementCommand = struct {
    image_id: u32,
    placement_id: u32,
    value: OutputPlacement,
    z: i32,
};

/// Places a child image within the z-index range available to applications.
/// For example: `try writePlacement(writer, command)`.
pub fn writePlacement(writer: *Io.Writer, command: PlacementCommand) Io.Writer.Error!usize {
    var clamped = command;
    clamped.z = std.math.clamp(command.z, -1000, 1000);
    return writePlacementAtZ(writer, clamped);
}

/// Places client chrome above the z-index range available to child
/// applications. Callers must use a fixed client-owned z value.
/// For example: `try writeUiPlacement(writer, command)`.
pub fn writeUiPlacement(writer: *Io.Writer, command: PlacementCommand) Io.Writer.Error!usize {
    std.debug.assert(command.z > 1000);
    return writePlacementAtZ(writer, command);
}

fn writePlacementAtZ(writer: *Io.Writer, command: PlacementCommand) Io.Writer.Error!usize {
    const value = command.value;
    var written = try printCounted(writer, "\x1b[{d};{d}H", .{ value.row + 1, value.column + 1 });
    written += try printCounted(
        writer,
        "\x1b_Ga=p,i={d},p={d},x={d},y={d},w={d},h={d},c={d},r={d},X={d},Y={d},z={d},C=1,q=2\x1b\\",
        .{ command.image_id, command.placement_id, value.source_x, value.source_y, value.source_width, value.source_height, value.columns, value.rows, value.offset_x, value.offset_y, command.z },
    );
    return written;
}

pub fn writeDeleteImage(writer: *Io.Writer, image_id: u32) Io.Writer.Error!usize {
    return printCounted(writer, "\x1b_Ga=d,d=I,i={d},q=2\x1b\\", .{image_id});
}

pub fn writeDeletePlacement(writer: *Io.Writer, image_id: u32, placement_id: u32) Io.Writer.Error!usize {
    return printCounted(writer, "\x1b_Ga=d,d=i,i={d},p={d},q=2\x1b\\", .{ image_id, placement_id });
}

pub fn writeDeleteImageRange(writer: *Io.Writer, first: u32, last: u32) Io.Writer.Error!usize {
    return printCounted(writer, "\x1b_Ga=d,d=R,x={d},y={d},q=2\x1b\\", .{ first, last });
}

test "PNG transmissions use encoded format without raw pixel dimensions" {
    var output: [8192]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    const progress = try writePngTransmissionChunks(&writer, .{
        .external_id = 0x90000001,
        .png = "encoded png bytes",
        .start_offset = 0,
        .budget = transmission_budget_per_frame,
    });
    try std.testing.expectEqual(@as(usize, 17), progress.offset);
    const bytes = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "a=t,f=100,t=d") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, ",s=") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, ",v=") == null);
}

/// Column of the shipped provider-mark atlas. Only built-in agents have
/// artwork; a configured agent draws its manifest glyph as cells instead.
pub const SidebarProvider = enum {
    claude,
    codex,
    pi,

    /// ```zig
    /// const column = SidebarProvider.fromAgent(mark.provider) orelse continue;
    /// ```
    pub fn fromAgent(provider: core.schema.AgentProvider) ?SidebarProvider {
        return switch (provider) {
            .claude => .claude,
            .codex => .codex,
            .pi => .pi,
            else => null,
        };
    }
};

pub const SidebarProviderPlacement = struct {
    area: core.ui.Rect,
    provider: SidebarProvider,
};

pub const SidebarFocus = struct {
    area: core.ui.Rect,
    color: [3]u8,
};

/// Media assets for the hybrid sidebar. Cells retain the complete fallback,
/// hover, text, and hit targets; graphics add only the rounded focus edge and
/// official provider artwork.
pub const KittySidebarRenderer = struct {
    const focused_card_id: u32 = 0x80000001;
    const focused_card_placement_id: u32 = 0x80000010;
    const provider_atlas_id: u32 = 0x80000003;
    const first_provider_placement_id: u32 = 0x80000100;
    const max_provider_placements = 64;
    const provider_count = 3;
    const provider_source_size = 256;
    const provider_source_width = provider_count * provider_source_size;
    const provider_raster_size = 64;
    const provider_source_pixels: []const u8 = @embedFile("../assets/provider-marks-768x256.rgba");
    // A flat rounded card needs little source resolution. This keeps its RGBA
    // payload plus the provider atlas comfortably inside one media pass even
    // after base64 expansion.
    const max_focused_card_pixels = 16 * 1024;

    comptime {
        std.debug.assert(provider_source_pixels.len == provider_source_width * provider_source_size * 4);
    }

    gpa: std.mem.Allocator,
    focused_card_pixels: []u8 = &.{},
    focused_card_width: u32 = 0,
    focused_card_height: u32 = 0,
    focused_card_color: [3]u8 = @splat(0),
    focused_card: ?core.ui.Rect = null,
    emitted_focused_card: ?core.ui.Rect = null,
    focused_card_dirty: bool = false,
    focused_card_emitted: bool = false,
    provider_atlas: []u8 = &.{},
    provider_slot_width: u32 = 0,
    provider_slot_height: u32 = 0,
    provider_atlas_width: u32 = 0,
    provider_atlas_height: u32 = 0,
    area: core.ui.Rect = .{},
    provider_marks: [max_provider_placements]SidebarProviderPlacement = undefined,
    provider_mark_count: u8 = 0,
    emitted_provider_mark_count: u8 = 0,
    provider_dirty: bool = false,
    placements_dirty: bool = false,
    visible: bool = false,
    emitted: bool = false,
    provider_emitted: bool = false,

    pub fn init(gpa: std.mem.Allocator) KittySidebarRenderer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(renderer: *KittySidebarRenderer) void {
        if (renderer.focused_card_pixels.len != 0) {
            renderer.gpa.free(renderer.focused_card_pixels);
        }
        if (renderer.provider_atlas.len != 0) {
            renderer.gpa.free(renderer.provider_atlas);
        }
    }

    pub fn retainedBytes(renderer: *const KittySidebarRenderer) usize {
        return renderer.focused_card_pixels.len + renderer.provider_atlas.len;
    }

    pub fn prepare(renderer: *KittySidebarRenderer, area: core.ui.Rect, focused_card: ?SidebarFocus, provider_marks: []const SidebarProviderPlacement, cell_width: u16, cell_height: u16) !void {
        if (provider_marks.len > max_provider_placements) {
            return error.TooManySidebarPlacements;
        }
        if (area.isEmpty() or cell_width == 0 or cell_height == 0) {
            renderer.visible = false;
            renderer.placements_dirty = renderer.emitted;
            return;
        }
        try renderer.prepareFocusedCard(focused_card, cell_width, cell_height);
        const provider_scale = @max(@as(u32, 1), provider_raster_size / @as(u32, @min(cell_width, cell_height)));
        const provider_slot_width = std.math.mul(u32, cell_width, provider_scale) catch return error.SidebarTooLarge;
        const provider_slot_height = std.math.mul(u32, cell_height, provider_scale) catch return error.SidebarTooLarge;
        const provider_atlas_width = std.math.mul(u32, provider_count, provider_slot_width) catch return error.SidebarTooLarge;
        const provider_atlas_height = provider_slot_height;
        const provider_atlas_len = try rgbaLength(provider_atlas_width, provider_atlas_height);
        const resized = renderer.provider_slot_width != provider_slot_width or
            renderer.provider_slot_height != provider_slot_height;
        if (resized) {
            const next_provider_atlas = try renderer.gpa.alloc(u8, provider_atlas_len);
            if (renderer.provider_atlas.len != 0) {
                renderer.gpa.free(renderer.provider_atlas);
            }
            renderer.provider_atlas = next_provider_atlas;
            renderer.provider_slot_width = provider_slot_width;
            renderer.provider_slot_height = provider_slot_height;
            renderer.provider_atlas_width = provider_atlas_width;
            renderer.provider_atlas_height = provider_atlas_height;
            renderProviderAtlas(
                renderer.provider_atlas,
                provider_atlas_width,
                provider_atlas_height,
                provider_slot_width,
                provider_slot_height,
            );
            renderer.provider_emitted = false;
            renderer.provider_dirty = provider_marks.len != 0;
            renderer.placements_dirty = true;
        }
        if (!renderer.visible) {
            renderer.provider_dirty = provider_marks.len != 0;
            renderer.placements_dirty = true;
        }
        if (!std.meta.eql(renderer.area, area)) {
            renderer.placements_dirty = true;
        }
        if (!providerPlacementsEqual(renderer.provider_marks[0..renderer.provider_mark_count], provider_marks)) {
            @memcpy(renderer.provider_marks[0..provider_marks.len], provider_marks);
            renderer.provider_mark_count = @intCast(provider_marks.len);
            renderer.placements_dirty = true;
        }
        if (provider_marks.len != 0 and !renderer.provider_emitted) {
            renderer.provider_dirty = true;
        }
        renderer.area = area;
        renderer.visible = true;
    }

    fn prepareFocusedCard(renderer: *KittySidebarRenderer, focused: ?SidebarFocus, cell_width: u16, cell_height: u16) !void {
        const next_card = if (focused) |value| value.area else null;
        if (!std.meta.eql(renderer.focused_card, next_card)) {
            renderer.placements_dirty = true;
        }
        renderer.focused_card = next_card;
        const value = focused orelse {
            renderer.focused_card_dirty = false;
            return;
        };
        const target_width = std.math.mul(u32, value.area.w, cell_width) catch
            return error.SidebarTooLarge;
        const target_height = std.math.mul(u32, value.area.h, cell_height) catch
            return error.SidebarTooLarge;
        const raster_size = fitWithinPixels(
            target_width,
            target_height,
            max_focused_card_pixels,
        );
        const changed = renderer.focused_card_width != raster_size.width or
            renderer.focused_card_height != raster_size.height or
            !std.mem.eql(u8, &renderer.focused_card_color, &value.color);
        if (!changed) {
            if (!renderer.focused_card_emitted) {
                renderer.focused_card_dirty = true;
            }
            return;
        }
        const byte_len = try rgbaLength(raster_size.width, raster_size.height);
        const next_pixels = try renderer.gpa.alloc(u8, byte_len);
        errdefer renderer.gpa.free(next_pixels);
        const target_radius = @max(@as(u32, 2), @min(@as(u32, 12), cell_height / 3));
        const raster_radius = @max(
            @as(u32, 1),
            (@as(u64, target_radius) * raster_size.width + target_width / 2) / target_width,
        );
        renderRoundedRectangle(
            next_pixels,
            raster_size.width,
            raster_size.height,
            @intCast(raster_radius),
            value.color,
        );
        if (renderer.focused_card_pixels.len != 0) {
            renderer.gpa.free(renderer.focused_card_pixels);
        }
        renderer.focused_card_pixels = next_pixels;
        renderer.focused_card_width = raster_size.width;
        renderer.focused_card_height = raster_size.height;
        renderer.focused_card_color = value.color;
        renderer.focused_card_dirty = true;
        renderer.placements_dirty = true;
    }

    pub fn damaged(renderer: *const KittySidebarRenderer) bool {
        return renderer.focused_card_dirty or renderer.provider_dirty or renderer.placements_dirty;
    }

    /// Emits pending sidebar images and placements. Geometry comes from what
    /// `prepare` rasterized: taking live cell sizes here let a resize between
    /// the two calls mismatch the placement against the pixels.
    pub fn write(renderer: *KittySidebarRenderer, writer: *Io.Writer) Io.Writer.Error!usize {
        if (!renderer.damaged()) {
            return 0;
        }
        var written: usize = 0;
        if (!renderer.visible) {
            if (renderer.focused_card_emitted) {
                written += try writeDeleteImage(writer, focused_card_id);
            }
            if (renderer.provider_emitted) {
                written += try writeDeleteImage(writer, provider_atlas_id);
            }
            renderer.emitted = false;
            renderer.focused_card_emitted = false;
            renderer.emitted_focused_card = null;
            renderer.focused_card_dirty = false;
            renderer.provider_emitted = false;
            renderer.emitted_provider_mark_count = 0;
            renderer.provider_dirty = false;
            renderer.placements_dirty = false;
            return written;
        }
        if (renderer.focused_card_dirty) {
            written += try writeTransmission(writer, .{
                .external_id = focused_card_id,
                .image = .{
                    .key = .{ .image_id = focused_card_id, .generation = 1 },
                    .format = .rgba,
                    .width = renderer.focused_card_width,
                    .height = renderer.focused_card_height,
                    .byte_len = renderer.focused_card_pixels.len,
                },
                .pixels = renderer.focused_card_pixels,
            });
            renderer.focused_card_emitted = true;
        }
        if (renderer.provider_dirty) {
            written += try writeTransmission(writer, .{
                .external_id = provider_atlas_id,
                .image = .{
                    .key = .{ .image_id = provider_atlas_id, .generation = 1 },
                    .format = .rgba,
                    .width = renderer.provider_atlas_width,
                    .height = renderer.provider_atlas_height,
                    .byte_len = renderer.provider_atlas.len,
                },
                .pixels = renderer.provider_atlas,
            });
            renderer.provider_emitted = true;
        }
        if (renderer.placements_dirty) {
            if (renderer.emitted_focused_card != null) {
                written += try writeDeletePlacement(
                    writer,
                    focused_card_id,
                    focused_card_placement_id,
                );
            }
            if (renderer.focused_card) |card| {
                if (renderer.focused_card_emitted) {
                    written += try writePlacement(writer, .{
                        .image_id = focused_card_id,
                        .placement_id = focused_card_placement_id,
                        .value = .{
                            .column = card.x,
                            .row = card.y,
                            .offset_x = 0,
                            .offset_y = 0,
                            .source_x = 0,
                            .source_y = 0,
                            .source_width = renderer.focused_card_width,
                            .source_height = renderer.focused_card_height,
                            .columns = card.w,
                            .rows = card.h,
                        },
                        .z = -9,
                    });
                }
            }
            renderer.emitted_focused_card = renderer.focused_card;
            for (0..renderer.emitted_provider_mark_count) |index| written += try writeDeletePlacement(
                writer,
                provider_atlas_id,
                first_provider_placement_id + @as(u32, @intCast(index)),
            );
            for (renderer.provider_marks[0..renderer.provider_mark_count], 0..) |mark, index| {
                written += try writePlacement(writer, .{
                    .image_id = provider_atlas_id,
                    .placement_id = first_provider_placement_id + @as(u32, @intCast(index)),
                    .value = .{
                        .column = mark.area.x,
                        .row = mark.area.y,
                        .offset_x = 0,
                        .offset_y = 0,
                        .source_x = @as(u32, @intFromEnum(mark.provider)) * renderer.provider_slot_width,
                        .source_y = 0,
                        .source_width = renderer.provider_slot_width,
                        .source_height = renderer.provider_slot_height,
                        .columns = mark.area.w,
                        .rows = mark.area.h,
                    },
                    .z = -8,
                });
            }
            renderer.emitted_provider_mark_count = renderer.provider_mark_count;
        }
        renderer.focused_card_dirty = false;
        renderer.provider_dirty = false;
        renderer.placements_dirty = false;
        renderer.emitted = true;
        return written;
    }
};

fn providerPlacementsEqual(a: []const SidebarProviderPlacement, b: []const SidebarProviderPlacement) bool {
    if (a.len != b.len) {
        return false;
    }
    for (a, b) |left, right| if (!std.meta.eql(left, right)) return false;
    return true;
}

fn rgbaLength(width: u32, height: u32) !usize {
    const pixels = std.math.mul(usize, width, height) catch return error.SidebarTooLarge;
    return std.math.mul(usize, pixels, 4) catch return error.SidebarTooLarge;
}

const PixelSize = struct {
    width: u32,
    height: u32,
};

fn fitWithinPixels(width: u32, height: u32, max_pixels: usize) PixelSize {
    if (@as(u64, width) * height <= max_pixels) {
        return .{ .width = width, .height = height };
    }
    const longest = @max(width, height);
    var lower: u32 = 1;
    var upper = longest;
    while (lower < upper) {
        const candidate = lower + (upper - lower + 1) / 2;
        const candidate_width = scaledPixelDimension(width, candidate, longest);
        const candidate_height = scaledPixelDimension(height, candidate, longest);
        if (@as(u64, candidate_width) * candidate_height <= max_pixels) {
            lower = candidate;
        } else {
            upper = candidate - 1;
        }
    }
    return .{
        .width = scaledPixelDimension(width, lower, longest),
        .height = scaledPixelDimension(height, lower, longest),
    };
}

fn scaledPixelDimension(value: u32, fitted_longest: u32, original_longest: u32) u32 {
    return @max(1, @as(u32, @intCast(
        (@as(u64, value) * fitted_longest + original_longest / 2) / original_longest,
    )));
}

fn renderRoundedRectangle(pixels: []u8, width: u32, height: u32, requested_radius: u32, color: [3]u8) void {
    const radius = @min(requested_radius, @min(width, height) / 2);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const index = (@as(usize, y) * width + x) * 4;
            pixels[index] = color[0];
            pixels[index + 1] = color[1];
            pixels[index + 2] = color[2];
            pixels[index + 3] = roundedCoverage(x, y, width, height, radius);
        }
    }
}

fn roundedCoverage(x: u32, y: u32, width: u32, height: u32, radius: u32) u8 {
    if (radius == 0) {
        return 255;
    }
    const supersample: u32 = 4;
    const units_per_pixel: u32 = supersample * 2;
    var inside: u32 = 0;
    for (0..supersample) |sample_y| {
        for (0..supersample) |sample_x| {
            const point_x = x * units_per_pixel + @as(u32, @intCast(sample_x * 2 + 1));
            const point_y = y * units_per_pixel + @as(u32, @intCast(sample_y * 2 + 1));
            inside += @intFromBool(insideRoundedRectangle(
                point_x,
                point_y,
                width * units_per_pixel,
                height * units_per_pixel,
                radius * units_per_pixel,
            ));
        }
    }
    return @intCast((inside * 255 + supersample * supersample / 2) /
        (supersample * supersample));
}

fn insideRoundedRectangle(x: u32, y: u32, width: u32, height: u32, radius: u32) bool {
    if ((x >= radius and x <= width - radius) or
        (y >= radius and y <= height - radius))
    {
        return true;
    }
    const center_x = if (x < radius) radius else width - radius;
    const center_y = if (y < radius) radius else height - radius;
    const delta_x = @as(i64, x) - center_x;
    const delta_y = @as(i64, y) - center_y;
    return delta_x * delta_x + delta_y * delta_y <= @as(i64, radius) * radius;
}

fn clearRgba(pixels: []u8) void {
    @memset(pixels, 0);
}

fn renderProviderAtlas(destination: []u8, atlas_width: u32, atlas_height: u32, slot_width: u32, slot_height: u32) void {
    std.debug.assert(atlas_width == providerAtlasSourceCount() * slot_width);
    std.debug.assert(atlas_height == slot_height);
    clearRgba(destination);
    const icon_size = @min(slot_width, slot_height);
    const offset_x = (slot_width - icon_size) / 2;
    const offset_y = (slot_height - icon_size) / 2;
    var provider: u32 = 0;
    while (provider < providerAtlasSourceCount()) : (provider += 1) {
        var y: u32 = 0;
        while (y < icon_size) : (y += 1) {
            var x: u32 = 0;
            while (x < icon_size) : (x += 1) {
                const destination_x = provider * slot_width + offset_x + x;
                const destination_y = offset_y + y;
                const destination_index = (@as(usize, destination_y) * atlas_width + destination_x) * 4;
                sampleProviderPixel(
                    destination[destination_index..][0..4],
                    provider,
                    x,
                    y,
                    icon_size,
                );
            }
        }
    }
}

fn sampleProviderPixel(destination: *[4]u8, provider: u32, destination_x: u32, destination_y: u32, destination_size: u32) void {
    const source_x = sampleAxis(destination_x, destination_size);
    const source_y = sampleAxis(destination_y, destination_size);
    const one: u64 = 1 << 16;
    const weights = [4]u64{
        (one - source_x.fraction) * (one - source_y.fraction),
        source_x.fraction * (one - source_y.fraction),
        (one - source_x.fraction) * source_y.fraction,
        source_x.fraction * source_y.fraction,
    };
    const pixels = [4][4]u8{
        providerSourcePixel(provider, source_x.index, source_y.index),
        providerSourcePixel(provider, source_x.next, source_y.index),
        providerSourcePixel(provider, source_x.index, source_y.next),
        providerSourcePixel(provider, source_x.next, source_y.next),
    };
    const total_weight: u64 = one * one;
    var alpha_sum: u64 = 0;
    var premultiplied: [3]u64 = @splat(0);
    for (pixels, weights) |pixel, weight| {
        alpha_sum += @as(u64, pixel[3]) * weight;
        inline for (0..3) |channel|
            premultiplied[channel] += @as(u64, pixel[channel]) * pixel[3] * weight;
    }
    destination[3] = @intCast((alpha_sum + total_weight / 2) / total_weight);
    if (alpha_sum == 0) {
        destination[0] = 0;
        destination[1] = 0;
        destination[2] = 0;
        return;
    }
    inline for (0..3) |channel|
        destination[channel] = @intCast((premultiplied[channel] + alpha_sum / 2) / alpha_sum);
}

const SampleAxis = struct {
    index: u32,
    next: u32,
    fraction: u64,
};

fn sampleAxis(destination: u32, destination_size: u32) SampleAxis {
    const source_last = KittySidebarRenderer.provider_source_size - 1;
    if (destination_size <= 1) {
        return .{
            .index = source_last / 2,
            .next = source_last / 2,
            .fraction = 0,
        };
    }
    const fixed = @as(u64, destination) * source_last * (1 << 16) /
        (destination_size - 1);
    const index: u32 = @intCast(fixed >> 16);
    return .{
        .index = index,
        .next = @min(source_last, index + 1),
        .fraction = fixed & 0xffff,
    };
}

fn providerSourcePixel(provider: u32, x: u32, y: u32) [4]u8 {
    const source_x = provider * KittySidebarRenderer.provider_source_size + x;
    const index = (@as(usize, y) * KittySidebarRenderer.provider_source_width + source_x) * 4;
    return KittySidebarRenderer.provider_source_pixels[index..][0..4].*;
}

fn providerAtlasSourceCount() u32 {
    return KittySidebarRenderer.provider_count;
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
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 10, .rows = 5 });

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
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 10, .rows = 5 });

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
        try model.addRoot(@enumFromInt(1), location, .{ .cols = 10, .rows = 5 });
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
    try model.addRoot(pane_id, location, .{ .cols = 10, .rows = 5 });

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
    try model.addRoot(pane_id, .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 10, .rows = 5 });
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
    try model.addRoot(pane_id, .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 10, .rows = 5 });
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
    try model.addRoot(pane_id, .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 10, .rows = 5 });
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

test "sidebar provider marks preserve aspect ratio and reuse their atlas" {
    var renderer = KittySidebarRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    const area: core.ui.Rect = .{ .x = 1, .y = 1, .w = 8, .h = 8 };
    const providers = [_]SidebarProviderPlacement{
        .{
            .area = .{ .x = 3, .y = 5, .w = 2, .h = 2 },
            .provider = .claude,
        },
        .{
            .area = .{ .x = 3, .y = 7, .w = 2, .h = 2 },
            .provider = .codex,
        },
        .{
            .area = .{ .x = 3, .y = 9, .w = 2, .h = 2 },
            .provider = .pi,
        },
    };
    try renderer.prepare(area, null, &providers, 10, 20);
    try std.testing.expectEqual(@as(u32, 60), renderer.provider_slot_width);
    try std.testing.expectEqual(@as(u32, 120), renderer.provider_slot_height);
    var initial_buffer: [128 * 1024]u8 = undefined;
    var initial = Io.Writer.fixed(&initial_buffer);
    _ = try renderer.write(&initial);
    try std.testing.expect(std.mem.indexOf(u8, initial.buffered(), "a=t") != null);
    try std.testing.expect(std.mem.indexOf(u8, initial.buffered(), "x=60,y=0,w=60,h=120,c=2,r=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, initial.buffered(), "x=120,y=0,w=60,h=120,c=2,r=2") != null);
    try std.testing.expect(renderer.provider_emitted);

    try renderer.prepare(area, null, &providers, 10, 20);
    try std.testing.expect(!renderer.damaged());

    // A cell-size change while no agents are visible must still invalidate the
    // resident atlas before a later provider reuses it.
    try renderer.prepare(area, null, &.{}, 9, 18);
    var cleared_buffer: [4096]u8 = undefined;
    var cleared = Io.Writer.fixed(&cleared_buffer);
    _ = try renderer.write(&cleared);
    try std.testing.expect(!renderer.provider_emitted);

    try renderer.prepare(area, null, &providers, 9, 18);
    try std.testing.expect(renderer.provider_dirty);
    var resized_buffer: [128 * 1024]u8 = undefined;
    var resized = Io.Writer.fixed(&resized_buffer);
    _ = try renderer.write(&resized);
    try std.testing.expect(std.mem.indexOf(u8, resized.buffered(), "x=63,y=0,w=63,h=126,c=2,r=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, resized.buffered(), "x=126,y=0,w=63,h=126,c=2,r=2") != null);
}

test "sidebar focused card is rounded bounded and moves without retransmission" {
    var renderer = KittySidebarRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    const area: core.ui.Rect = .{ .x = 1, .y = 1, .w = 60, .h = 20 };
    const color = [3]u8{ 35, 35, 35 };
    const first: SidebarFocus = .{
        .area = .{ .x = 2, .y = 4, .w = 57, .h = 3 },
        .color = color,
    };
    try renderer.prepare(area, first, &.{}, 10, 20);
    try std.testing.expect(
        renderer.focused_card_pixels.len <= KittySidebarRenderer.max_focused_card_pixels * 4,
    );
    try std.testing.expect(renderer.focused_card_pixels[3] < 255);
    const center = ((@as(usize, renderer.focused_card_height) / 2 * renderer.focused_card_width +
        renderer.focused_card_width / 2) * 4);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 35, 35, 35, 255 },
        renderer.focused_card_pixels[center..][0..4],
    );

    var initial_buffer: [512 * 1024]u8 = undefined;
    var initial = Io.Writer.fixed(&initial_buffer);
    _ = try renderer.write(&initial);
    try std.testing.expect(std.mem.indexOf(u8, initial.buffered(), "a=t") != null);
    try std.testing.expect(std.mem.indexOf(u8, initial.buffered(), "a=p") != null);
    try std.testing.expect(std.mem.indexOf(u8, initial.buffered(), "z=-9") != null);

    const moved: SidebarFocus = .{
        .area = .{ .x = 2, .y = 8, .w = 57, .h = 3 },
        .color = color,
    };
    try renderer.prepare(area, moved, &.{}, 10, 20);
    var moved_buffer: [4096]u8 = undefined;
    var moved_writer = Io.Writer.fixed(&moved_buffer);
    _ = try renderer.write(&moved_writer);
    try std.testing.expect(std.mem.indexOf(u8, moved_writer.buffered(), "a=p") != null);
    try std.testing.expect(std.mem.indexOf(u8, moved_writer.buffered(), "a=t") == null);
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
    try model.addRoot(pane_id, .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 10, .rows = 5 });
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
    try model.addRoot(pane_id, .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 10, .rows = 5 });
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
    try model.addRoot(pane_id, .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 10, .rows = 5 });
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
    try model.addRoot(pane_id, .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 10, .rows = 5 });
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
