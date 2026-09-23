const core = @import("telar-core");
const shared_transfer = @import("shared_transfer.zig");
const PreparedTransfer = @import("PreparedTransfer.zig");
const PaneMediaAllocator = @import("PaneMediaAllocator.zig");
const std = @import("std");
/// Bounded parking space for frozen generations plus the memory of which
/// generation was frozen last per image, so an adopted frame is never frozen
/// twice and a replaced one is released the moment its successor lands.
///
/// Written only by the pane's media actor while it owns the media borrow and
/// read only by the runtime thread while the actor is idle; the completion
/// event that ends the borrow is the fence between them.
const PreparedTransfers = @This();

items: [shared_transfer.max_prepared]?PreparedTransfer = @splat(null),
frozen: [core.max_images_per_pane]?FrozenGeneration = @splat(null),

/// Whether `key` (or a newer generation of its image) was already frozen.
///
/// ```zig
/// if (prepared.covers(key)) continue;
/// ```
pub fn covers(self: *const PreparedTransfers, key: core.ImageKey) bool {
    for (self.frozen) |slot| {
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
pub fn put(self: *PreparedTransfers, transfer: PreparedTransfer, media: *PaneMediaAllocator) bool {
    const image_id = transfer.metadata.key.image_id;
    var free_slot: ?usize = null;
    for (&self.items, 0..) |*slot, index| {
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
    self.items[index] = transfer;
    self.rememberFrozen(transfer.metadata.key);
    return true;
}

/// Hands out the frozen generation for `key`, if any. Ownership of the
/// object and its reservation moves to the caller.
///
/// ```zig
/// if (pane.media_ingestion.prepared_transfers.take(key)) |frozen| adopt(frozen);
/// ```
pub fn take(self: *PreparedTransfers, key: core.ImageKey) ?PreparedTransfer {
    for (&self.items) |*slot| {
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
pub fn holds(self: *const PreparedTransfers, key: core.ImageKey) bool {
    for (self.items) |slot| {
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
pub fn discardAll(self: *PreparedTransfers, media: *PaneMediaAllocator) void {
    for (&self.items) |*slot| {
        const existing = slot.* orelse continue;
        existing.discard(media);
        slot.* = null;
    }
    self.frozen = @splat(null);
}

/// Releases the parked frame for `key`, if any.
///
/// ```zig
/// prepared.discard(key, media);
/// ```
pub fn discard(self: *PreparedTransfers, key: core.ImageKey, media: *PaneMediaAllocator) void {
    if (self.take(key)) |existing| {
        existing.discard(media);
    }
}

/// Forgets images the emulator no longer holds, releasing any parked
/// object of theirs. `alive` answers whether an image id still exists.
///
/// ```zig
/// prepared.retain(storage, media);
/// ```
pub fn retain(self: *PreparedTransfers, alive: anytype, media: *PaneMediaAllocator) void {
    for (&self.items) |*slot| {
        const existing = slot.* orelse continue;
        if (alive.holds(existing.metadata.key)) {
            continue;
        }
        existing.discard(media);
        slot.* = null;
    }
    for (&self.frozen) |*slot| {
        const frozen = slot.* orelse continue;
        if (alive.holdsImage(frozen.image_id)) {
            continue;
        }
        slot.* = null;
    }
}

fn rememberFrozen(self: *PreparedTransfers, key: core.ImageKey) void {
    var free_slot: ?usize = null;
    for (&self.frozen, 0..) |*slot, index| {
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
        self.frozen[index] = .{ .image_id = key.image_id, .generation = key.generation };
    }
}

const FrozenGeneration = struct {
    image_id: u32,
    generation: u64,
};
