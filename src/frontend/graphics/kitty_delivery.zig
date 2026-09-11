//! Kitty delivery state. The shared catalog owns pixels, quotas and revisions.

const ImageStateType = @import("ImageState.zig");
const PlacementStateType = @import("PlacementState.zig");
const GenericResourceStore = @import("telar-client").GenericResourceStore;
const Compression = @import("Compression.zig");
const std = @import("std");
const kitty = @import("kitty.zig");
const supportsSharedMemory = @import("telar-client").supportsSharedMemory;
const PaneIdType = @import("telar-core").PaneId;
const ImageIdentity = @import("telar-client").ImageIdentity;
const PartialPlacement = @import("PartialPlacement.zig");
const enabled_module = @import("telar-core").enabled;
const PlacementIdentity = @import("telar-client").PlacementIdentity;

pub const Store = GenericResourceStore(@This());
const ImageEntry = Store.ImageEntry;
const PlacementEntry = Store.PlacementEntry;

pub const State = @import("State.zig");
pub const ImageState = @import("ImageState.zig");
pub const PlacementState = @import("PlacementState.zig");
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
    if (!store.delivery.host_zlib or entry.pixels.len < kitty.compression_min_bytes) {
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
        state.allocating = std.Io.Writer.Allocating.initCapacity(store.gpa, 4096) catch {
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
                store.delivery.compression_input = store.gpa.alloc(u8, kitty.compression_slice_per_frame) catch {
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
        if (store.delivery.pass_counter -% image.delivery.transmitted_pass < kitty.shared_consume_deadline_passes) {
            continue;
        }
        if (sharedPixelsConsumed(store, image)) {
            continue;
        }
        loseSharedName(store, entry.key_ptr.pane_id, image);
        store.delivery.shared_expiries +|= 1;
        if (store.delivery.shared_expiries >= kitty.shared_expiry_disable_threshold) {
            store.shared_memory = false;
        }
    }
}

pub fn loseSharedName(store: *Store, pane_id: PaneIdType, image: *ImageEntry) void {
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

pub fn queueDelete(store: *Store, value: kitty.Delete) void {
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

pub fn popDelete(store: *Store) ?kitty.Delete {
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

pub fn imageCreated(store: *Store) !ImageStateType {
    return .{ .external_id = try allocateImageId(store) };
}
pub fn placementCreated(store: *Store) !PlacementStateType {
    return .{ .external_id = try allocatePlacementId(store) };
}
pub const releaseImage = freeCompression;
pub fn imageDeleted(store: *Store, entry: ImageEntry) void {
    if (comptime enabled_module) {
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
