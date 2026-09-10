//! Bounded image ingestion, allocation, revisions and retained-resource credits.
//! Delivery owns its extension state and reports when a retired image is free.
const std = @import("std");
const builtin = @import("builtin");
const native = @cImport({
    @cInclude("sys/stat.h");
});
const core = @import("telar-core");
const schema = core.schema;
const graphics = core.graphics;

pub const ImageIdentity = struct {
    pane_id: schema.PaneId,
    image_id: u32,
    generation: u64,
};

pub const PlacementIdentity = struct {
    pane_id: schema.PaneId,
    virtual_id: u64,
};

pub const SharedPixels = struct {
    name: [64]u8 = undefined,
    len: u8,

    pub fn slice(shared: *const SharedPixels) []const u8 {
        return shared.name[0..shared.len];
    }

    pub fn sliceZ(shared: *const SharedPixels) [:0]const u8 {
        return shared.name[0..shared.len :0];
    }
};

pub const PixelAllocation = struct {
    pixels: []u8,
    shared: ?SharedPixels = null,
};

pub fn supportsSharedMemory() bool {
    return builtin.os.tag != .windows and !builtin.abi.isAndroid() and builtin.link_libc;
}

pub fn identity(pane_id: schema.PaneId, key: graphics.ImageKey) ImageIdentity {
    return .{ .pane_id = pane_id, .image_id = key.image_id, .generation = key.generation };
}

/// Creates one resource catalog with an explicit image-delivery lifetime policy.
/// Example: `var assets = ResourceStore(Delivery).init(gpa);`.
pub fn ResourceStore(comptime Delivery: type) type {
    return struct {
        const Self = @This();
        pub const ImageEntry = struct {
            metadata: graphics.Image,
            pixels: []u8,
            shared: ?SharedPixels = null,
            received: usize = 0,
            chunks: usize = 0,
            retire_pending: bool = false,
            credit_on_release: bool = true,
            delivery: Delivery.ImageState = .{},
        };
        pub const PlacementEntry = struct {
            placement: graphics.Placement,
            delivery: Delivery.PlacementState = .{},
        };

        pub const Credit = struct { pane_id: schema.PaneId, bytes: usize };
        pub const PaneUsage = struct {
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
        total_bytes: usize = 0,
        next_shm_id: u64 = 1,
        shared_memory: bool = false,
        damage: bool = false,
        ingress_revision: u64 = 0,
        revisions: std.AutoHashMapUnmanaged(schema.PaneId, RevisionState) = .{},
        hidden_panes: std.AutoHashMapUnmanaged(schema.PaneId, void) = .{},
        usage: std.AutoHashMapUnmanaged(schema.PaneId, PaneUsage) = .{},

        delivery: Delivery.State = .{},
        const ImageCommit = struct {
            pane_id: schema.PaneId,
            image: graphics.Image,
            allocation: *PixelAllocation,
            received: usize,
        };
        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn initSharedMemory(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa, .shared_memory = supportsSharedMemory() };
        }

        pub fn deinit(store: *Self) void {
            Delivery.deinit(store);

            var images = store.images.iterator();
            while (images.next()) |entry| store.freePixels(entry.value_ptr);
            store.images.deinit(store.gpa);
            store.placements.deinit(store.gpa);
            store.revisions.deinit(store.gpa);
            store.hidden_panes.deinit(store.gpa);
            store.usage.deinit(store.gpa);
        }

        pub fn ingressVersion(store: *const Self) u64 {
            return store.ingress_revision;
        }

        fn allocatePixels(store: *Self, byte_len: usize) !PixelAllocation {
            if (store.shared_memory) {
                if (store.allocateSharedPixels(byte_len)) |allocation| {
                    return allocation;
                } else |_| {}
            }
            return .{ .pixels = try store.gpa.alloc(u8, byte_len) };
        }

        fn allocateSharedPixels(store: *Self, byte_len: usize) !PixelAllocation {
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

        pub fn freeAllocation(store: *Self, allocation: *PixelAllocation) void {
            if (allocation.pixels.len == 0) {
                return;
            }
            if (allocation.shared) |*shared| {
                if (comptime supportsSharedMemory()) {
                    _ = std.c.shm_unlink(shared.sliceZ());
                    std.posix.munmap(@alignCast(allocation.pixels));
                }
            } else {
                store.gpa.free(allocation.pixels);
            }
            allocation.pixels = &.{};
            allocation.shared = null;
        }

        fn freePixels(store: *Self, entry: *ImageEntry) void {
            Delivery.releaseImage(store, entry);
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

        pub fn applySnapshot(store: *Self, message: schema.graphics.Snapshot) !void {
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

        pub fn applyImage(store: *Self, message: schema.graphics.Image) !void {
            if (!try store.acceptRevision(message.pane_id, message.revision)) {
                return;
            }
            const byte_len = try store.admitImage(message.pane_id, message.image);
            var allocation = try store.allocatePixels(byte_len);
            errdefer store.freeAllocation(&allocation);
            try store.commitImage(.{ .pane_id = message.pane_id, .image = message.image, .allocation = &allocation, .received = 0 });
            store.noteIngressChange();
        }

        pub fn applySharedImage(store: *Self, message: schema.graphics.SharedImage) !void {
            if (comptime !supportsSharedMemory()) {
                return error.GraphicsSharedMappingFailed;
            }

            var adopted = false;
            defer if (!adopted) {
                _ = std.c.shm_unlink(message.name.sliceZ());
            };

            if (!try store.acceptRevision(message.pane_id, message.revision)) {
                return;
            }
            const byte_len = try store.admitImage(message.pane_id, message.image);
            var allocation = store.mapSharedPixels(message.name, byte_len) catch return error.GraphicsSharedMappingFailed;
            errdefer store.freeAllocation(&allocation);
            try store.commitImage(.{ .pane_id = message.pane_id, .image = message.image, .allocation = &allocation, .received = byte_len });
            adopted = true;
            store.removeOtherGenerations(message.pane_id, message.image.key);
            store.noteIngressChange();
        }

        fn mapSharedPixels(store: *Self, name: graphics.ShmName, byte_len: usize) !PixelAllocation {
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

        fn admitImage(store: *Self, pane_id: schema.PaneId, image: graphics.Image) !usize {
            const byte_len = try image.validate(graphics.max_image_bytes_per_pane);
            const key = identity(pane_id, image.key);
            // A new header supersedes every transfer of this image id that never
            // finished, so evict those before quota accounting rather than let a
            // retransmission flood count against the pane.
            store.evictReplacedGenerations(pane_id, image.key);
            const previous = store.images.get(key);
            if (previous) |entry| {
                if (!Delivery.canRelease(store, key, &entry)) {
                    return error.GraphicsResyncRequired;
                }
            }

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
                store.noteImageRemoved(pane_id, removed.value);
                var removed_entry = removed.value;
                Delivery.imageDeleted(store, removed.value);
                store.freePixels(&removed_entry);
            }
            return byte_len;
        }

        fn commitImage(store: *Self, commit: ImageCommit) !void {
            const byte_len = commit.allocation.pixels.len;
            const delivery = try Delivery.imageCreated(store);
            const usage = try store.usageFor(commit.pane_id);
            try store.images.put(store.gpa, identity(commit.pane_id, commit.image.key), .{
                .metadata = commit.image,
                .pixels = commit.allocation.pixels,
                .shared = commit.allocation.shared,
                .received = commit.received,
                .delivery = delivery,
            });
            commit.allocation.pixels = &.{};
            commit.allocation.shared = null;
            usage.count += 1;
            usage.bytes += byte_len;
            store.total_bytes += byte_len;
            store.damage = true;
        }

        pub fn applyChunk(store: *Self, message: schema.graphics.ImageChunk) !void {
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

        pub fn applyPlacement(store: *Self, message: schema.graphics.Placement) !void {
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
                Delivery.placementChanged(store, key, entry);
            } else {
                if (store.panePlacementCount(pane_id) == graphics.max_placements_per_pane) {
                    return error.GraphicsPlacementLimitExceeded;
                }
                const usage = try store.usageFor(pane_id);
                const delivery = try Delivery.placementCreated(store);
                try store.placements.put(store.gpa, key, .{
                    .placement = placement,
                    .delivery = delivery,
                });
                usage.placements += 1;
                Delivery.placementChanged(store, key, store.placements.getPtr(key).?);
            }
            store.damage = true;
            store.noteIngressChange();
        }

        pub fn deleteImage(store: *Self, message: schema.graphics.DeleteImage) !void {
            if (!try store.acceptRevision(message.pane_id, message.revision)) {
                return;
            }
            if (store.deleteImageData(message.pane_id, message.key)) {
                store.noteIngressChange();
            }
        }

        fn deleteImageData(store: *Self, pane_id: schema.PaneId, key: graphics.ImageKey) bool {
            const image_key = identity(pane_id, key);
            const image = store.images.getPtr(image_key) orelse return false;
            image.retire_pending = true;
            store.removePlacementsForImage(pane_id, key);
            store.collectRetired(pane_id, key.image_id);
            store.damage = true;

            return true;
        }

        pub fn removeImageData(store: *Self, key: ImageIdentity) void {
            const removed = store.images.fetchRemove(key) orelse return;
            store.total_bytes -= removed.value.pixels.len;
            store.noteImageRemoved(key.pane_id, removed.value);
            var removed_entry = removed.value;
            Delivery.imageDeleted(store, removed.value);
            store.freePixels(&removed_entry);
        }

        fn removePlacementsForImage(store: *Self, pane_id: schema.PaneId, key: graphics.ImageKey) void {
            var iterator = store.placements.iterator();
            while (iterator.next()) |entry| {
                if (entry.key_ptr.pane_id == pane_id and
                    std.meta.eql(entry.value_ptr.placement.key, key))
                {
                    Delivery.placementDeleted(store, entry.value_ptr.*);
                    _ = store.placements.removeByPtr(entry.key_ptr);
                    store.notePlacementRemoved(pane_id);
                }
            }
        }

        pub fn deletePlacement(store: *Self, message: schema.graphics.DeletePlacement) !void {
            if (!try store.acceptRevision(message.pane_id, message.revision)) {
                return;
            }
            const key: PlacementIdentity = .{
                .pane_id = message.pane_id,
                .virtual_id = message.virtual_id,
            };
            const removed = store.placements.fetchRemove(key) orelse return;
            store.notePlacementRemoved(message.pane_id);
            Delivery.placementDeleted(store, removed.value);
            store.collectRetired(message.pane_id, message.key.image_id);
            store.damage = true;
            store.noteIngressChange();
        }

        pub fn noteIngressChange(store: *Self) void {
            store.ingress_revision +%= 1;
        }

        pub fn clearPane(store: *Self, pane_id: schema.PaneId) void {
            store.clearPaneData(pane_id, false);
            store.removeRevision(pane_id);
            store.setPaneVisible(pane_id, true) catch {};
        }

        fn clearPaneData(store: *Self, pane_id: schema.PaneId, release_credit: bool) void {
            var placements = store.placements.iterator();
            while (placements.next()) |entry| {
                if (entry.key_ptr.pane_id != pane_id) {
                    continue;
                }

                Delivery.placementDeleted(store, entry.value_ptr.*);
                _ = store.placements.removeByPtr(entry.key_ptr);
            }

            var images = store.images.iterator();
            while (images.next()) |entry| {
                if (entry.key_ptr.pane_id != pane_id) {
                    continue;
                }

                entry.value_ptr.retire_pending = true;
                if (!release_credit) {
                    entry.value_ptr.credit_on_release = false;
                }
            }

            if (store.usage.getPtr(pane_id)) |usage| {
                if (!release_credit) {
                    usage.released_bytes = 0;
                }

                usage.placements = 0;
                store.pruneUsage(pane_id, usage.*);
            }

            store.collectRetired(pane_id, null);
            store.damage = true;
        }

        pub fn peekCredit(store: *Self) ?Credit {
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

        pub fn consumeCredit(store: *Self, credit: Credit) void {
            const usage = store.usage.getPtr(credit.pane_id) orelse unreachable;
            std.debug.assert(credit.bytes != 0 and credit.bytes <= usage.released_bytes);
            usage.released_bytes -= credit.bytes;
            store.pruneUsage(credit.pane_id, usage.*);
        }

        pub fn setPaneVisible(store: *Self, pane_id: schema.PaneId, visible: bool) !void {
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
                Delivery.placementVisibility(store, entry.value_ptr, visible);
            }
            if (!visible) {
                store.collectRetired(pane_id, null);
            }
            store.damage = true;
        }

        pub fn paneVisible(store: *const Self, pane_id: schema.PaneId) bool {
            return !store.hidden_panes.contains(pane_id);
        }

        pub fn hasPaneGraphics(store: *const Self, pane_id: schema.PaneId) bool {
            const usage = store.usage.get(pane_id) orelse return false;
            return usage.count != 0;
        }

        fn panePlacementCount(store: *const Self, pane_id: schema.PaneId) usize {
            const usage = store.usage.get(pane_id) orelse return 0;
            return usage.placements;
        }

        fn usageFor(store: *Self, pane_id: schema.PaneId) !*PaneUsage {
            const entry = try store.usage.getOrPut(store.gpa, pane_id);
            if (!entry.found_existing) {
                entry.value_ptr.* = .{};
            }
            return entry.value_ptr;
        }

        fn noteImageRemoved(store: *Self, pane_id: schema.PaneId, image: ImageEntry) void {
            const usage = store.usage.getPtr(pane_id) orelse return;
            usage.count -= 1;
            usage.bytes -= image.pixels.len;
            if (image.credit_on_release) {
                usage.released_bytes +|= image.pixels.len;
            }

            store.pruneUsage(pane_id, usage.*);
        }

        fn notePlacementRemoved(store: *Self, pane_id: schema.PaneId) void {
            const usage = store.usage.getPtr(pane_id) orelse return;
            usage.placements -= 1;
            store.pruneUsage(pane_id, usage.*);
        }

        fn pruneUsage(store: *Self, pane_id: schema.PaneId, usage: PaneUsage) void {
            if (usage.count == 0 and usage.placements == 0 and usage.released_bytes == 0) {
                _ = store.usage.remove(pane_id);
            }
        }

        fn paneLogicalImageCount(store: *const Self, pane_id: schema.PaneId, replacing_id: u32) usize {
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

        fn hasImageId(store: *const Self, pane_id: schema.PaneId, image_id: u32) bool {
            var iterator = store.images.iterator();
            while (iterator.next()) |entry| {
                if (entry.key_ptr.pane_id == pane_id and entry.key_ptr.image_id == image_id) {
                    return true;
                }
            }
            return false;
        }

        fn removeOtherGenerations(store: *Self, pane_id: schema.PaneId, current: graphics.ImageKey) void {
            store.retireOtherGenerations(pane_id, current);
        }

        fn evictReplacedGenerations(store: *Self, pane_id: schema.PaneId, incoming: graphics.ImageKey) void {
            store.retireOtherGenerations(pane_id, incoming);
        }

        fn retireOtherGenerations(store: *Self, pane_id: schema.PaneId, current: graphics.ImageKey) void {
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

        pub fn collectRetired(store: *Self, pane_id: ?schema.PaneId, image_id: ?u32) void {
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
                        store.hasPlacementReference(entry.key_ptr.*) or
                        !Delivery.canRelease(store, entry.key_ptr.*, entry.value_ptr))
                    {
                        continue;
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

        fn removeIncomplete(store: *Self, pane_id: schema.PaneId) void {
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
                store.noteImageRemoved(pane_id, entry.value_ptr.*);
                Delivery.imageDeleted(store, entry.value_ptr.*);
                store.freePixels(entry.value_ptr);
                _ = store.images.removeByPtr(entry.key_ptr);
                store.damage = true;
            }
        }

        fn revisionState(store: *Self, pane_id: schema.PaneId) !*RevisionState {
            const entry = try store.revisions.getOrPut(store.gpa, pane_id);
            if (!entry.found_existing) {
                entry.value_ptr.* = .{};
            }
            return entry.value_ptr;
        }

        fn acceptRevision(store: *Self, pane_id: schema.PaneId, value: u64) !bool {
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

        fn removeRevision(store: *Self, pane_id: schema.PaneId) void {
            _ = store.revisions.remove(pane_id);
        }

        fn hasPlacementReference(store: *const Self, key: ImageIdentity) bool {
            var placements = store.placements.iterator();
            while (placements.next()) |entry| {
                if (entry.key_ptr.pane_id == key.pane_id and
                    entry.value_ptr.placement.key.image_id == key.image_id and
                    entry.value_ptr.placement.key.generation == key.generation)
                {
                    return true;
                }
            }
            return false;
        }
    };
}
