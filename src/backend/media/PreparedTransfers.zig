/// Bounded parking space for frozen generations plus the memory of which
/// generation was frozen last per image, so an adopted frame is never frozen
/// twice and a replaced one is released the moment its successor lands.
///
/// Written only by the pane's media actor while it owns the media borrow and
/// read only by the runtime thread while the actor is idle; the completion
/// event that ends the borrow is the fence between them.
const PreparedTransfers = @This();
const source_namespace = @import("shared_transfer.zig");
const PreparedTransfer = @import("PreparedTransfer.zig");
const core = @import("telar-core");
const FrozenGeneration = @import("FrozenGeneration.zig");
const std = @import("std");
items: [source_namespace.max_prepared]?PreparedTransfer = @splat(null),
frozen: [core.graphics.max_images_per_pane]?FrozenGeneration = @splat(null),

/// Whether `key` (or a newer generation of its image) was already frozen.
///
/// ```zig
/// if (prepared.covers(key)) continue;
/// ```
pub fn covers(prepared: *const PreparedTransfers, key: core.graphics.ImageKey) bool {
    for (prepared.frozen) |slot| {
        const frozen = slot orelse continue;
        if (frozen.image_id == key.image_id) {
            return frozen.generation >= key.generation;
        }
    }
    return false;
}

/// Parks one frozen generation. An older unadopted generation of the same
/// image is released first. Returns false when no slot is free; the
/// caller then discards the object itself.
///
/// ```zig
/// if (!prepared.put(transfer, media)) transfer.discard(media);
/// ```
pub fn put(prepared: *PreparedTransfers, transfer: PreparedTransfer, media: *source_namespace.PaneMediaAllocator) bool {
    const image_id = transfer.metadata.key.image_id;
    var free_slot: ?usize = null;
    for (&prepared.items, 0..) |*slot, index| {
        if (slot.*) |existing| {
            if (existing.metadata.key.image_id != image_id) {
                continue;
            }
            existing.discard(media);
            slot.* = null;
            free_slot = index;
            break;
        } else if (free_slot == null) {
            free_slot = index;
        }
    }
    const index = free_slot orelse return false;
    prepared.items[index] = transfer;
    prepared.rememberFrozen(transfer.metadata.key);
    return true;
}

/// Hands out the frozen generation for `key`, if any. Ownership of the
/// object and its reservation moves to the caller.
///
/// ```zig
/// if (pane.media_ingestion.prepared_transfers.take(key)) |frozen| adopt(frozen);
/// ```
pub fn take(prepared: *PreparedTransfers, key: core.graphics.ImageKey) ?PreparedTransfer {
    for (&prepared.items) |*slot| {
        const existing = slot.* orelse continue;
        if (!std.meta.eql(existing.metadata.key, key)) {
            continue;
        }
        slot.* = null;
        return existing;
    }
    return null;
}

/// Whether a frozen generation for `key` is parked here.
pub fn holds(prepared: *const PreparedTransfers, key: core.graphics.ImageKey) bool {
    for (prepared.items) |slot| {
        const existing = slot orelse continue;
        if (std.meta.eql(existing.metadata.key, key)) {
            return true;
        }
    }
    return false;
}

/// Releases every parked object and reservation.
///
/// ```zig
/// pane.media_ingestion.prepared_transfers.discardAll(&pane.media_allocator);
/// ```
pub fn discardAll(prepared: *PreparedTransfers, media: *source_namespace.PaneMediaAllocator) void {
    for (&prepared.items) |*slot| {
        const existing = slot.* orelse continue;
        existing.discard(media);
        slot.* = null;
    }
    prepared.frozen = @splat(null);
}

/// Releases the parked frame for `key`, if any.
///
/// ```zig
/// prepared.discard(key, media);
/// ```
pub fn discard(prepared: *PreparedTransfers, key: core.graphics.ImageKey, media: *source_namespace.PaneMediaAllocator) void {
    if (prepared.take(key)) |existing| {
        existing.discard(media);
    }
}

/// Forgets images the emulator no longer holds, releasing any parked
/// object of theirs. `alive` answers whether an image id still exists.
///
/// ```zig
/// prepared.retain(storage, media);
/// ```
pub fn retain(prepared: *PreparedTransfers, alive: anytype, media: *source_namespace.PaneMediaAllocator) void {
    for (&prepared.items) |*slot| {
        const existing = slot.* orelse continue;
        if (alive.holds(existing.metadata.key)) {
            continue;
        }
        existing.discard(media);
        slot.* = null;
    }
    for (&prepared.frozen) |*slot| {
        const frozen = slot.* orelse continue;
        if (alive.holdsImage(frozen.image_id)) {
            continue;
        }
        slot.* = null;
    }
}

fn rememberFrozen(prepared: *PreparedTransfers, key: core.graphics.ImageKey) void {
    var free_slot: ?usize = null;
    for (&prepared.frozen, 0..) |*slot, index| {
        if (slot.*) |frozen| {
            if (frozen.image_id != key.image_id) {
                continue;
            }
            slot.* = .{ .image_id = key.image_id, .generation = key.generation };
            return;
        } else if (free_slot == null) {
            free_slot = index;
        }
    }
    if (free_slot) |index| {
        prepared.frozen[index] = .{ .image_id = key.image_id, .generation = key.generation };
    }
}
