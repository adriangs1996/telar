const core = @import("telar-core");
const CreditType = @import("Credit.zig");
const SharedPixels = @import("SharedPixels.zig");
const std = @import("std");
const ImageIdentity = @import("ImageIdentity.zig");
const PlacementIdentity = @import("PlacementIdentity.zig");
const PixelAllocation = @import("PixelAllocation.zig");
const store_ops = @import("store.zig");

/// Creates one resource catalog with an explicit image-delivery lifetime policy.
/// Example: `var assets = ResourceStore(Delivery).init(gpa);`.
pub fn Type(comptime Delivery: type) type {
    return struct {
        const Self = @This();
        pub const ImageEntry = struct {
            metadata: core.Image,
            pixels: []u8,
            shared: ?SharedPixels = null,
            received: usize = 0,
            chunks: usize = 0,
            retire_pending: bool = false,
            credit_on_release: bool = true,
            delivery: Delivery.ImageState = .{},
        };
        pub const PlacementEntry = struct {
            placement: core.Placement,
            delivery: Delivery.PlacementState = .{},
        };

        pub const Credit = CreditType;
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
        revisions: std.AutoHashMapUnmanaged(core.PaneId, RevisionState) = .{},
        hidden_panes: std.AutoHashMapUnmanaged(core.PaneId, void) = .{},
        usage: std.AutoHashMapUnmanaged(core.PaneId, PaneUsage) = .{},

        delivery: Delivery.State = .{},
        const ImageCommit = struct {
            pane_id: core.PaneId,
            image: core.Image,
            allocation: *PixelAllocation,
            received: usize,
        };
        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn initSharedMemory(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa, .shared_memory = store_ops.supportsSharedMemory() };
        }

        pub fn deinit(self: *Self) void {
            Delivery.deinit(self);

            var images = self.images.iterator();
            while (images.next()) |entry| self.freePixels(entry.value_ptr);
            self.images.deinit(self.gpa);
            self.placements.deinit(self.gpa);
            self.revisions.deinit(self.gpa);
            self.hidden_panes.deinit(self.gpa);
            self.usage.deinit(self.gpa);
        }

        pub fn ingressVersion(self: *const Self) u64 {
            return self.ingress_revision;
        }

        fn allocatePixels(self: *Self, byte_len: usize) !PixelAllocation {
            if (self.shared_memory) {
                if (self.allocateSharedPixels(byte_len)) |allocation| {
                    return allocation;
                } else |_| {}
            }
            return .{ .pixels = try self.gpa.alloc(u8, byte_len) };
        }

        fn allocateSharedPixels(self: *Self, byte_len: usize) !PixelAllocation {
            if (comptime !store_ops.supportsSharedMemory()) {
                return error.SharedMemoryUnavailable;
            }

            var attempts: u8 = 0;
            while (attempts < 8) : (attempts += 1) {
                const sequence = self.next_shm_id;
                self.next_shm_id +%= 1;
                if (self.next_shm_id == 0) {
                    self.next_shm_id = 1;
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

        pub fn freeAllocation(self: *Self, allocation: *PixelAllocation) void {
            if (allocation.pixels.len == 0) {
                return;
            }
            if (allocation.shared) |*shared| {
                if (comptime store_ops.supportsSharedMemory()) {
                    _ = std.c.shm_unlink(shared.sliceZ());
                    std.posix.munmap(@alignCast(allocation.pixels));
                }
            } else {
                self.gpa.free(allocation.pixels);
            }
            allocation.pixels = &.{};
            allocation.shared = null;
        }

        fn freePixels(self: *Self, entry: *ImageEntry) void {
            Delivery.releaseImage(self, entry);
            if (entry.shared) |*shared| {
                if (comptime store_ops.supportsSharedMemory()) {
                    _ = std.c.shm_unlink(shared.sliceZ());
                    std.posix.munmap(@alignCast(entry.pixels));
                }
            } else {
                self.gpa.free(entry.pixels);
            }
            entry.pixels = &.{};
            entry.shared = null;
        }

        pub fn applySnapshot(self: *Self, message: core.Snapshot) !void {
            const revision = try self.revisionState(message.pane_id);
            switch (message.phase) {
                .begin => {
                    self.clearPaneData(message.pane_id, true);
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
                    self.removeIncomplete(message.pane_id);
                    revision.latest = message.revision;
                    revision.snapshot = null;
                },
            }

            self.noteIngressChange();
        }

        pub fn applyImage(self: *Self, message: core.SchemaImage) !void {
            if (!try self.acceptRevision(message.pane_id, message.revision)) {
                return;
            }
            const byte_len = try self.admitImage(message.pane_id, message.image);
            var allocation = try self.allocatePixels(byte_len);
            errdefer self.freeAllocation(&allocation);
            try self.commitImage(.{ .pane_id = message.pane_id, .image = message.image, .allocation = &allocation, .received = 0 });
            self.noteIngressChange();
        }

        pub fn applySharedImage(self: *Self, message: core.SharedImage) !void {
            if (comptime !store_ops.supportsSharedMemory()) {
                return error.GraphicsSharedMappingFailed;
            }

            var adopted = false;
            defer if (!adopted) {
                _ = std.c.shm_unlink(message.name.sliceZ());
            };

            if (!try self.acceptRevision(message.pane_id, message.revision)) {
                return;
            }
            const byte_len = try self.admitImage(message.pane_id, message.image);
            var allocation = self.mapSharedPixels(message.name, byte_len) catch return error.GraphicsSharedMappingFailed;
            errdefer self.freeAllocation(&allocation);
            try self.commitImage(.{ .pane_id = message.pane_id, .image = message.image, .allocation = &allocation, .received = byte_len });
            adopted = true;
            self.removeOtherGenerations(message.pane_id, message.image.key);
            self.noteIngressChange();
        }

        fn mapSharedPixels(self: *Self, name: core.ShmName, byte_len: usize) !PixelAllocation {
            _ = self;
            if (comptime !store_ops.supportsSharedMemory()) {
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
            var stat: store_ops.native.struct_stat = undefined;
            if (store_ops.native.fstat(fd, &stat) != 0) {
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

        fn admitImage(self: *Self, pane_id: core.PaneId, image: core.Image) !usize {
            const byte_len = try image.validate(core.max_image_bytes_per_pane);
            const key = store_ops.identity(pane_id, image.key);
            // A new header supersedes every transfer of this image id that never
            // finished, so evict those before quota accounting rather than let a
            // retransmission flood count against the pane.
            self.evictReplacedGenerations(pane_id, image.key);
            const previous = self.images.get(key);
            if (previous) |entry| {
                if (!Delivery.canRelease(self, key, &entry)) {
                    return error.GraphicsResyncRequired;
                }
            }

            const pane_usage: PaneUsage = self.usage.get(pane_id) orelse .{};
            const logical_count = self.paneLogicalImageCount(pane_id, image.key.image_id);
            const replacing = self.hasImageId(pane_id, image.key.image_id);
            if (previous == null and !replacing and logical_count >= core.max_images_per_pane) {
                return error.GraphicsImageLimitExceeded;
            }
            const previous_len = if (previous) |entry| entry.pixels.len else 0;
            const next_pane_bytes = std.math.add(
                usize,
                pane_usage.bytes - previous_len,
                byte_len,
            ) catch return error.GraphicsQuotaExceeded;
            if (next_pane_bytes > core.max_image_bytes_per_pane) {
                return error.GraphicsQuotaExceeded;
            }
            const next_total = std.math.add(
                usize,
                self.total_bytes - previous_len,
                byte_len,
            ) catch return error.GraphicsQuotaExceeded;
            if (next_total > core.max_image_bytes_global) {
                return error.GraphicsQuotaExceeded;
            }

            if (self.images.fetchRemove(key)) |removed| {
                self.total_bytes -= removed.value.pixels.len;
                self.noteImageRemoved(pane_id, removed.value);
                var removed_entry = removed.value;
                Delivery.imageDeleted(self, removed.value);
                self.freePixels(&removed_entry);
            }
            return byte_len;
        }

        fn commitImage(self: *Self, commit: ImageCommit) !void {
            const byte_len = commit.allocation.pixels.len;
            const delivery = try Delivery.imageCreated(self);
            const usage = try self.usageFor(commit.pane_id);
            try self.images.put(self.gpa, store_ops.identity(commit.pane_id, commit.image.key), .{
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
            self.total_bytes += byte_len;
            self.damage = true;
        }

        pub fn applyChunk(self: *Self, message: core.ImageChunk) !void {
            if (!try self.acceptRevision(message.pane_id, message.revision)) {
                return;
            }
            const entry = self.images.getPtr(store_ops.identity(message.pane_id, message.key)) orelse
                return error.UnknownGraphicsImage;
            if (message.offset != entry.received) {
                return error.InvalidGraphicsChunkOffset;
            }
            if (entry.chunks == core.max_chunks_per_image) {
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
                self.removeOtherGenerations(message.pane_id, key);
                self.damage = true;
            }

            self.noteIngressChange();
        }

        pub fn applyPlacement(self: *Self, message: core.SchemaPlacement) !void {
            if (!try self.acceptRevision(message.pane_id, message.revision)) {
                return;
            }
            const pane_id = message.pane_id;
            const placement = message.placement;
            const image = self.images.get(store_ops.identity(pane_id, placement.key)) orelse
                return error.UnknownGraphicsImage;
            _ = try placement.sourceRect(image.metadata);
            const key: PlacementIdentity = .{ .pane_id = pane_id, .virtual_id = placement.virtual_id };
            if (self.placements.getPtr(key)) |entry| {
                entry.placement = placement;
                Delivery.placementChanged(self, key, entry);
            } else {
                if (self.panePlacementCount(pane_id) == core.max_placements_per_pane) {
                    return error.GraphicsPlacementLimitExceeded;
                }
                const usage = try self.usageFor(pane_id);
                const delivery = try Delivery.placementCreated(self);
                try self.placements.put(self.gpa, key, .{
                    .placement = placement,
                    .delivery = delivery,
                });
                usage.placements += 1;
                Delivery.placementChanged(self, key, self.placements.getPtr(key).?);
            }
            self.damage = true;
            self.noteIngressChange();
        }

        pub fn deleteImage(self: *Self, message: core.DeleteImage) !void {
            if (!try self.acceptRevision(message.pane_id, message.revision)) {
                return;
            }
            if (self.deleteImageData(message.pane_id, message.key)) {
                self.noteIngressChange();
            }
        }

        fn deleteImageData(self: *Self, pane_id: core.PaneId, key: core.ImageKey) bool {
            const image_key = store_ops.identity(pane_id, key);
            const image = self.images.getPtr(image_key) orelse return false;
            image.retire_pending = true;
            self.removePlacementsForImage(pane_id, key);
            self.collectRetired(pane_id, key.image_id);
            self.damage = true;

            return true;
        }

        pub fn removeImageData(self: *Self, key: ImageIdentity) void {
            const removed = self.images.fetchRemove(key) orelse return;
            self.total_bytes -= removed.value.pixels.len;
            self.noteImageRemoved(key.pane_id, removed.value);
            var removed_entry = removed.value;
            Delivery.imageDeleted(self, removed.value);
            self.freePixels(&removed_entry);
        }

        fn removePlacementsForImage(self: *Self, pane_id: core.PaneId, key: core.ImageKey) void {
            var iterator = self.placements.iterator();
            while (iterator.next()) |entry| {
                if (entry.key_ptr.pane_id == pane_id and
                    std.meta.eql(entry.value_ptr.placement.key, key))
                {
                    Delivery.placementDeleted(self, entry.value_ptr.*);
                    _ = self.placements.removeByPtr(entry.key_ptr);
                    self.notePlacementRemoved(pane_id);
                }
            }
        }

        pub fn deletePlacement(self: *Self, message: core.DeletePlacement) !void {
            if (!try self.acceptRevision(message.pane_id, message.revision)) {
                return;
            }
            const key: PlacementIdentity = .{
                .pane_id = message.pane_id,
                .virtual_id = message.virtual_id,
            };
            const removed = self.placements.fetchRemove(key) orelse return;
            self.notePlacementRemoved(message.pane_id);
            Delivery.placementDeleted(self, removed.value);
            self.collectRetired(message.pane_id, message.key.image_id);
            self.damage = true;
            self.noteIngressChange();
        }

        pub fn noteIngressChange(self: *Self) void {
            self.ingress_revision +%= 1;
        }

        pub fn clearPane(self: *Self, pane_id: core.PaneId) void {
            self.clearPaneData(pane_id, false);
            self.removeRevision(pane_id);
            self.setPaneVisible(pane_id, true) catch {};
        }

        fn clearPaneData(self: *Self, pane_id: core.PaneId, release_credit: bool) void {
            var placements = self.placements.iterator();
            while (placements.next()) |entry| {
                if (entry.key_ptr.pane_id != pane_id) {
                    continue;
                }

                Delivery.placementDeleted(self, entry.value_ptr.*);
                _ = self.placements.removeByPtr(entry.key_ptr);
            }

            var images = self.images.iterator();
            while (images.next()) |entry| {
                if (entry.key_ptr.pane_id != pane_id) {
                    continue;
                }

                entry.value_ptr.retire_pending = true;
                if (!release_credit) {
                    entry.value_ptr.credit_on_release = false;
                }
            }

            if (self.usage.getPtr(pane_id)) |usage| {
                if (!release_credit) {
                    usage.released_bytes = 0;
                }

                usage.placements = 0;
                self.pruneUsage(pane_id, usage.*);
            }

            self.collectRetired(pane_id, null);
            self.damage = true;
        }

        pub fn peekCredit(self: *Self) ?Credit {
            var usage = self.usage.iterator();
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

        pub fn consumeCredit(self: *Self, credit: Credit) void {
            const usage = self.usage.getPtr(credit.pane_id) orelse unreachable;
            std.debug.assert(credit.bytes != 0 and credit.bytes <= usage.released_bytes);
            usage.released_bytes -= credit.bytes;
            self.pruneUsage(credit.pane_id, usage.*);
        }

        pub fn setPaneVisible(self: *Self, pane_id: core.PaneId, visible: bool) !void {
            if (visible) {
                _ = self.hidden_panes.remove(pane_id);
            } else {
                try self.hidden_panes.put(self.gpa, pane_id, {});
            }
            var iterator = self.placements.iterator();
            while (iterator.next()) |entry| {
                if (entry.key_ptr.pane_id != pane_id) {
                    continue;
                }
                Delivery.placementVisibility(self, entry.value_ptr, visible);
            }
            if (!visible) {
                self.collectRetired(pane_id, null);
            }
            self.damage = true;
        }

        pub fn paneVisible(self: *const Self, pane_id: core.PaneId) bool {
            return !self.hidden_panes.contains(pane_id);
        }

        pub fn hasPaneGraphics(self: *const Self, pane_id: core.PaneId) bool {
            const usage = self.usage.get(pane_id) orelse return false;
            return usage.count != 0;
        }

        fn panePlacementCount(self: *const Self, pane_id: core.PaneId) usize {
            const usage = self.usage.get(pane_id) orelse return 0;
            return usage.placements;
        }

        fn usageFor(self: *Self, pane_id: core.PaneId) !*PaneUsage {
            const entry = try self.usage.getOrPut(self.gpa, pane_id);
            if (!entry.found_existing) {
                entry.value_ptr.* = .{};
            }
            return entry.value_ptr;
        }

        fn noteImageRemoved(self: *Self, pane_id: core.PaneId, image: ImageEntry) void {
            const usage = self.usage.getPtr(pane_id) orelse return;
            usage.count -= 1;
            usage.bytes -= image.pixels.len;
            if (image.credit_on_release) {
                usage.released_bytes +|= image.pixels.len;
            }

            self.pruneUsage(pane_id, usage.*);
        }

        fn notePlacementRemoved(self: *Self, pane_id: core.PaneId) void {
            const usage = self.usage.getPtr(pane_id) orelse return;
            usage.placements -= 1;
            self.pruneUsage(pane_id, usage.*);
        }

        fn pruneUsage(self: *Self, pane_id: core.PaneId, usage: PaneUsage) void {
            if (usage.count == 0 and usage.placements == 0 and usage.released_bytes == 0) {
                _ = self.usage.remove(pane_id);
            }
        }

        fn paneLogicalImageCount(self: *const Self, pane_id: core.PaneId, replacing_id: u32) usize {
            var ids: [core.max_images_per_pane]u32 = undefined;
            var count: usize = 0;
            var replacing_present = false;
            var iterator = self.images.iterator();
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

        fn hasImageId(self: *const Self, pane_id: core.PaneId, image_id: u32) bool {
            var iterator = self.images.iterator();
            while (iterator.next()) |entry| {
                if (entry.key_ptr.pane_id == pane_id and entry.key_ptr.image_id == image_id) {
                    return true;
                }
            }
            return false;
        }

        fn removeOtherGenerations(self: *Self, pane_id: core.PaneId, current: core.ImageKey) void {
            self.retireOtherGenerations(pane_id, current);
        }

        fn evictReplacedGenerations(self: *Self, pane_id: core.PaneId, incoming: core.ImageKey) void {
            self.retireOtherGenerations(pane_id, incoming);
        }

        fn retireOtherGenerations(self: *Self, pane_id: core.PaneId, current: core.ImageKey) void {
            var images = self.images.iterator();
            while (images.next()) |entry| {
                if (entry.key_ptr.pane_id != pane_id or
                    entry.key_ptr.image_id != current.image_id or
                    entry.key_ptr.generation == current.generation)
                {
                    continue;
                }
                entry.value_ptr.retire_pending = true;
            }
            self.collectRetired(pane_id, current.image_id);
        }

        pub fn collectRetired(self: *Self, pane_id: ?core.PaneId, image_id: ?u32) void {
            // Retransmissions bypass the logical image count, so sweep in bounded
            // batches instead of assuming one fixed array holds every generation.
            var retired: [core.max_images_per_pane]ImageIdentity = undefined;
            while (true) {
                var count: usize = 0;
                var images = self.images.iterator();
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
                        self.hasPlacementReference(entry.key_ptr.*) or
                        !Delivery.canRelease(self, entry.key_ptr.*, entry.value_ptr))
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
                for (retired[0..count]) |key| self.removeImageData(key);
            }
        }

        fn removeIncomplete(self: *Self, pane_id: core.PaneId) void {
            var placements = self.placements.iterator();
            while (placements.next()) |entry| {
                if (entry.key_ptr.pane_id != pane_id) {
                    continue;
                }
                const image = self.images.get(store_ops.identity(
                    pane_id,
                    entry.value_ptr.placement.key,
                )) orelse {
                    _ = self.placements.removeByPtr(entry.key_ptr);
                    self.notePlacementRemoved(pane_id);
                    self.damage = true;
                    continue;
                };
                if (image.received != image.pixels.len) {
                    _ = self.placements.removeByPtr(entry.key_ptr);
                    self.notePlacementRemoved(pane_id);
                    self.damage = true;
                }
            }
            var iterator = self.images.iterator();
            while (iterator.next()) |entry| {
                if (entry.key_ptr.pane_id != pane_id or
                    entry.value_ptr.received == entry.value_ptr.pixels.len)
                {
                    continue;
                }
                self.total_bytes -= entry.value_ptr.pixels.len;
                self.noteImageRemoved(pane_id, entry.value_ptr.*);
                Delivery.imageDeleted(self, entry.value_ptr.*);
                self.freePixels(entry.value_ptr);
                _ = self.images.removeByPtr(entry.key_ptr);
                self.damage = true;
            }
        }

        fn revisionState(self: *Self, pane_id: core.PaneId) !*RevisionState {
            const entry = try self.revisions.getOrPut(self.gpa, pane_id);
            if (!entry.found_existing) {
                entry.value_ptr.* = .{};
            }
            return entry.value_ptr;
        }

        fn acceptRevision(self: *Self, pane_id: core.PaneId, value: u64) !bool {
            const state = try self.revisionState(pane_id);
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

        fn removeRevision(self: *Self, pane_id: core.PaneId) void {
            _ = self.revisions.remove(pane_id);
        }

        fn hasPlacementReference(self: *const Self, key: ImageIdentity) bool {
            var placements = self.placements.iterator();
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
