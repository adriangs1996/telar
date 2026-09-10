//! Kitty delivery state. The shared catalog owns pixels, quotas and revisions.
const std = @import("std");
const core = @import("telar-core");
const graphics = core.graphics;
const schema = core.schema;
const diagnostics = core.diagnostics;
const Io = std.Io;
const kitty = @import("kitty.zig");
const resources = @import("telar-client").graphics;
pub const Store = resources.ResourceStore(@This());
const ImageEntry = Store.ImageEntry;
const PlacementEntry = Store.PlacementEntry;
const ImageIdentity = resources.ImageIdentity;
const PlacementIdentity = resources.PlacementIdentity;
const SharedPixels = resources.SharedPixels;
const identity = resources.identity;
const supportsSharedMemory = resources.supportsSharedMemory;
const Compression = kitty.Compression;
const CompressionScheduler = kitty.CompressionScheduler;
const Delete = kitty.Delete;
const PartialTransmission = kitty.PartialTransmission;
const PartialPlacement = kitty.PartialPlacement;
const compression_slice_per_frame = kitty.compression_slice_per_frame;
const compression_min_bytes = kitty.compression_min_bytes;
const shared_consume_deadline_passes = kitty.shared_consume_deadline_passes;
const shared_expiry_disable_threshold = kitty.shared_expiry_disable_threshold;
pub const State = struct {
    delete_queue: [graphics.max_placements_per_pane * 2]Delete = undefined,
    delete_head: usize = 0,
    delete_len: usize = 0,
    delete_overflow: bool = false,
    next_image_id: u32 = 1,
    next_placement_id: u32 = 1,
    host_zlib: bool = false,
    compression_scheduler: ?CompressionScheduler = null,
    pending_compression: ?*Compression = null,
    orphan_compression: bool = false,
    compression_input: []u8 = &.{},
    pass_counter: u64 = 0,
    shared_expiries: u8 = 0,
    clock_ns: u64 = 0,
    retire_latency: diagnostics.Timing = .{},
    partial: ?PartialTransmission = null,
};
pub const ImageState = struct {
    external_id: u32 = 0,
    transmitted: bool = false,
    force_direct: bool = false,
    compressed: ?[]u8 = null,
    compression: ?*Compression = null,
    incompressible: bool = false,
    emitted_shared: bool = false,
    transmitted_pass: u64 = 0,
    transmitted_ns: u64 = 0,
    host_acked: bool = false,
};
pub const PlacementState = struct {
    external_id: u32 = 0,
    emitted_image_id: ?u32 = null,
    dirty: bool = true,
};
pub fn beginPresentation(store: *Store, now_ns: u64) void {
    store.delivery.pass_counter +%= 1;
    store.delivery.clock_ns = now_ns;
    expireSharedTransmissions(store);
}

pub fn completeTransmission(store: *Store, image: *ImageEntry, transport: enum { inline_data, shared_memory }) void {
    image.delivery.transmitted = true;
    switch (transport) {
        .inline_data => {
            freeCompression(store, image);
            store.delivery.partial = null;
        },
        .shared_memory => {
            image.delivery.emitted_shared = true;
            image.delivery.transmitted_pass = store.delivery.pass_counter;
            image.delivery.transmitted_ns = store.delivery.clock_ns;
        },
    }
}

pub fn recoverDeleteOverflow(store: *Store) void {
    store.delivery.delete_head = 0;
    store.delivery.delete_len = 0;
    store.delivery.delete_overflow = false;
    var reset_images = store.images.iterator();
    while (reset_images.next()) |entry| {
        entry.value_ptr.delivery.transmitted = false;
        entry.value_ptr.delivery.force_direct = true;
    }
    var reset_placements = store.placements.iterator();
    while (reset_placements.next()) |entry| {
        entry.value_ptr.delivery.emitted_image_id = null;
        entry.value_ptr.delivery.dirty = true;
    }
    store.collectRetired(null, null);
}

pub fn freeCompression(store: *Store, entry: *ImageEntry) void {
    if (entry.delivery.compression) |state| {
        if (store.delivery.pending_compression == state) {
            store.delivery.orphan_compression = true;
        } else {
            state.allocating.deinit();
            store.gpa.destroy(state);
        }

        entry.delivery.compression = null;
    }
    if (entry.delivery.compressed) |bytes| {
        store.gpa.free(bytes);
        entry.delivery.compressed = null;
    }
}

pub fn completeCompression(store: *Store, job: *Compression) void {
    std.debug.assert(store.delivery.pending_compression == job);
    store.delivery.pending_compression = null;
    if (store.delivery.orphan_compression) {
        job.allocating.deinit();
        store.gpa.destroy(job);
        store.delivery.orphan_compression = false;
    }

    store.damage = true;
}

pub fn advanceCompression(store: *Store, entry: *ImageEntry, budget: *usize) bool {
    if (entry.delivery.compressed != null or entry.delivery.incompressible) {
        return true;
    }
    if (!store.delivery.host_zlib or entry.pixels.len < compression_min_bytes) {
        return true;
    }
    if (budget.* == 0) {
        return false;
    }
    if (store.delivery.pending_compression != null) {
        return false;
    }

    const state = entry.delivery.compression orelse create: {
        const state = store.gpa.create(Compression) catch {
            entry.delivery.incompressible = true;
            return true;
        };
        // The compressor asserts a non-empty output buffer at init; the
        // allocating writer grows it past this seed as the stream needs.
        state.allocating = Io.Writer.Allocating.initCapacity(store.gpa, 4096) catch {
            store.gpa.destroy(state);
            entry.delivery.incompressible = true;
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
            entry.delivery.incompressible = true;
            return true;
        };
        entry.delivery.compression = state;
        break :create state;
    };
    if (store.delivery.compression_scheduler) |scheduler| {
        if (state.failed) {
            freeCompression(store, entry);
            entry.delivery.incompressible = true;
            return true;
        }
        if (state.offset < entry.pixels.len) {
            if (store.delivery.compression_input.len == 0) {
                store.delivery.compression_input = store.gpa.alloc(u8, compression_slice_per_frame) catch {
                    freeCompression(store, entry);
                    entry.delivery.incompressible = true;
                    return true;
                };
            }

            state.input = store.delivery.compression_input;
            const take = @min(budget.*, @min(state.input.len, entry.pixels.len - state.offset));
            @memcpy(state.input[0..take], entry.pixels[state.offset..][0..take]);
            state.input_len = take;
            state.offset += take;
            state.finish_after = state.offset == entry.pixels.len;
            budget.* -= take;
            store.delivery.pending_compression = state;
            scheduler.start(scheduler.context, state) catch {
                store.delivery.pending_compression = null;
                freeCompression(store, entry);
                entry.delivery.incompressible = true;
                return true;
            };

            return false;
        }
    } else {
        const take = @min(budget.*, entry.pixels.len - state.offset);
        state.compress.writer.writeAll(entry.pixels[state.offset..][0..take]) catch {
            freeCompression(store, entry);
            entry.delivery.incompressible = true;
            return true;
        };
        state.offset += take;
        budget.* -= take;
        if (state.offset < entry.pixels.len) {
            return false;
        }

        state.compress.finish() catch {
            freeCompression(store, entry);
            entry.delivery.incompressible = true;
            return true;
        };
    }
    const compressed = state.allocating.toOwnedSlice() catch {
        freeCompression(store, entry);
        entry.delivery.incompressible = true;
        return true;
    };
    state.allocating.deinit();
    store.gpa.destroy(state);
    entry.delivery.compression = null;
    // The saved wire bytes must justify the host's inflate work.
    if (compressed.len >= entry.pixels.len - entry.pixels.len / 8) {
        store.gpa.free(compressed);
        entry.delivery.incompressible = true;
    } else {
        entry.delivery.compressed = compressed;
    }
    return true;
}

pub fn sharedPixelsConsumed(_: *Store, entry: *const ImageEntry) bool {
    const shared = entry.shared orelse return true;
    if (!entry.delivery.emitted_shared) {
        return true;
    }
    if (entry.delivery.host_acked) {
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

pub fn expireSharedTransmissions(store: *Store) void {
    if (comptime !supportsSharedMemory()) {
        return;
    }
    var images = store.images.iterator();
    while (images.next()) |entry| {
        const image = entry.value_ptr;
        if (image.shared == null or !image.delivery.emitted_shared) {
            continue;
        }
        if (store.delivery.pass_counter -% image.delivery.transmitted_pass < shared_consume_deadline_passes) {
            continue;
        }
        if (sharedPixelsConsumed(store, image)) {
            continue;
        }
        loseSharedName(store, entry.key_ptr.pane_id, image);
        store.delivery.shared_expiries +|= 1;
        if (store.delivery.shared_expiries >= shared_expiry_disable_threshold) {
            store.shared_memory = false;
        }
    }
}

pub fn loseSharedName(store: *Store, pane_id: schema.PaneId, image: *ImageEntry) void {
    const shared = if (image.shared) |*value| value else return;
    _ = std.c.shm_unlink(shared.sliceZ());
    image.delivery.emitted_shared = false;
    image.delivery.host_acked = false;
    image.delivery.force_direct = true;
    image.delivery.transmitted = false;
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
        placement_entry.value_ptr.delivery.emitted_image_id = null;
        placement_entry.value_ptr.delivery.dirty = true;
    }
    store.damage = true;
}

pub fn noteHostReply(store: *Store, external_id: u32, ok: bool) bool {
    var images = store.images.iterator();
    while (images.next()) |entry| {
        const image = entry.value_ptr;
        if (image.delivery.external_id != external_id or !image.delivery.emitted_shared) {
            continue;
        }
        if (ok) {
            image.delivery.host_acked = true;
            store.collectRetired(entry.key_ptr.pane_id, entry.key_ptr.image_id);
        } else {
            loseSharedName(store, entry.key_ptr.pane_id, image);
        }
        store.noteIngressChange();
        return true;
    }
    return false;
}

pub fn hasPendingSharedRelease(store: *Store) bool {
    var images = store.images.iterator();
    while (images.next()) |entry| {
        if (!entry.value_ptr.retire_pending or
            exteriorGenerationLive(store, entry.key_ptr.*, entry.value_ptr.delivery.external_id))
        {
            continue;
        }
        if (!sharedPixelsConsumed(store, entry.value_ptr)) {
            return true;
        }
    }
    return false;
}

pub fn setHostZlib(store: *Store, supported: bool) void {
    store.delivery.host_zlib = supported;
}

pub fn invalidatePlacements(store: *Store) void {
    var iterator = store.placements.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.delivery.emitted_image_id) |image_id| {
            queueDelete(store, .{ .placement = .{
                .image_id = image_id,
                .placement_id = entry.value_ptr.delivery.external_id,
            } });
        }
        entry.value_ptr.delivery.emitted_image_id = null;
        entry.value_ptr.delivery.dirty = true;
    }
    store.collectRetired(null, null);
    store.damage = true;
}

pub fn allocateImageId(store: *Store) !u32 {
    if (store.delivery.next_image_id >= 0x40000000) {
        return error.GraphicsIdExhausted;
    }
    defer store.delivery.next_image_id += 1;
    return store.delivery.next_image_id;
}

pub fn allocatePlacementId(store: *Store) !u32 {
    if (store.delivery.next_placement_id >= 0x40000000) {
        return error.GraphicsIdExhausted;
    }
    defer store.delivery.next_placement_id += 1;
    return store.delivery.next_placement_id;
}

pub fn queueDelete(store: *Store, value: Delete) void {
    if (store.delivery.delete_len == store.delivery.delete_queue.len) {
        // Recover with one bounded range delete, then rebuild every
        // Telar-owned low-range image and placement. UI images live in the
        // high range and are not affected.
        store.delivery.delete_overflow = true;
        store.damage = true;
        return;
    }
    const index = (store.delivery.delete_head + store.delivery.delete_len) % store.delivery.delete_queue.len;
    store.delivery.delete_queue[index] = value;
    store.delivery.delete_len += 1;
}

pub fn popDelete(store: *Store) ?Delete {
    if (store.delivery.delete_len == 0) {
        return null;
    }
    const value = store.delivery.delete_queue[store.delivery.delete_head];
    store.delivery.delete_head = (store.delivery.delete_head + 1) % store.delivery.delete_queue.len;
    store.delivery.delete_len -= 1;
    return value;
}

pub fn exteriorGenerationLive(store: *const Store, key: ImageIdentity, external_id: u32) bool {
    if (store.delivery.partial) |partial| {
        if (std.meta.eql(partial.key, key)) {
            return true;
        }
    }
    var placements = store.placements.iterator();
    while (placements.next()) |entry| {
        if (entry.key_ptr.pane_id != key.pane_id) {
            continue;
        }
        if (entry.value_ptr.delivery.emitted_image_id == external_id or
            (entry.value_ptr.placement.key.image_id == key.image_id and
                entry.value_ptr.placement.key.generation == key.generation))
        {
            return true;
        }
    }
    return false;
}

pub fn rememberPartialPlacement(store: *Store, remembered: PartialPlacement) void {
    const partial = if (store.delivery.partial) |*value| value else return;
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

pub fn capturePartialPlacements(store: *Store) void {
    if (store.delivery.partial == null) {
        return;
    }
    var placements = store.placements.iterator();
    while (placements.next()) |entry| {
        rememberPartialPlacement(store, .{
            .pane_id = entry.key_ptr.pane_id,
            .placement = entry.value_ptr.placement,
            .external_id = entry.value_ptr.delivery.external_id,
        });
    }
}

pub fn imageCreated(store: *Store) !ImageState {
    return .{ .external_id = try allocateImageId(store) };
}
pub fn placementCreated(store: *Store) !PlacementState {
    return .{ .external_id = try allocatePlacementId(store) };
}
pub const releaseImage = freeCompression;
pub fn imageDeleted(store: *Store, entry: ImageEntry) void {
    if (comptime diagnostics.enabled) {
        if (entry.retire_pending and entry.delivery.emitted_shared and entry.delivery.transmitted_ns != 0 and store.delivery.clock_ns != 0) {
            store.delivery.retire_latency.observe(store.delivery.clock_ns -| entry.delivery.transmitted_ns);
        }
    }

    queueDelete(store, .{ .image = entry.delivery.external_id });
}
pub fn placementDeleted(store: *Store, entry: PlacementEntry) void {
    if (entry.delivery.emitted_image_id) |image_id| {
        queueDelete(store, .{ .placement = .{ .image_id = image_id, .placement_id = entry.delivery.external_id } });
    }
}
pub fn placementChanged(store: *Store, key: PlacementIdentity, entry: *PlacementEntry) void {
    entry.delivery.dirty = true;
    rememberPartialPlacement(store, .{ .pane_id = key.pane_id, .placement = entry.placement, .external_id = entry.delivery.external_id });
}
pub fn placementVisibility(store: *Store, entry: *PlacementEntry, visible: bool) void {
    if (!visible) {
        placementDeleted(store, entry.*);
    }
    entry.delivery.emitted_image_id = null;
    entry.delivery.dirty = visible;
}
pub fn canRelease(store: *Store, key: ImageIdentity, entry: *const ImageEntry) bool {
    if (exteriorGenerationLive(store, key, entry.delivery.external_id) or !sharedPixelsConsumed(store, entry)) {
        return false;
    }
    return true;
}
pub fn deinit(store: *Store) void {
    if (store.delivery.pending_compression) |job| {
        completeCompression(store, job);
    }
    store.gpa.free(store.delivery.compression_input);
}
