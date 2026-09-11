//! Attachment delivery for consumers that hold PNG bytes across media turns.

const SlotStateType = @import("SlotState.zig");
const LeaseType = @import("Lease.zig");
const GenericCatalog = @import("GenericCatalog.zig").Type;
const types = @import("types.zig");
const std = @import("std");

pub const Store = GenericCatalog(@This());
pub const State = @import("State.zig");
pub const SlotState = @import("SlotState.zig");
pub const Lease = @import("Lease.zig");

/// Pins one active PNG without borrowing its catalog slot.
/// Example: `const lease = try retain(&store, id); defer release(&store, lease);`.
pub fn retain(store: *Store, id: types.Id) !LeaseType {
    const slot = store.find(id) orelse return error.UnknownAttachment;
    if (slot.retire_pending) {
        return error.AttachmentRetired;
    }

    slot.delivery.leases = std.math.add(u32, slot.delivery.leases, 1) catch return error.AttachmentLeaseLimit;
    return .{ .id = id, .png = slot.png };
}

/// Returns one lease. Wiping and freeing remain in the catalog's media reap.
/// Example: `release(&store, lease); store.reapRetired();`.
pub fn release(store: *Store, lease: LeaseType) void {
    const slot = store.find(lease.id) orelse unreachable;
    std.debug.assert(slot.delivery.leases != 0);
    slot.delivery.leases -= 1;
}

pub fn createSlot(_: *Store) !SlotStateType {
    return .{};
}
pub fn targetChanged(_: *Store) void {}
pub fn retireSlot(_: *Store, _: usize) void {}
pub fn canRelease(slot: *const Store.Slot) bool {
    return slot.delivery.leases == 0;
}
