//! Native key identities are keycode + 1, bounded by both hosts' 256-key tables.
const std = @import("std");
const Key = @import("telar-client").Key;
const Recovery = @This();

pub const capacity = 256;
keys: [capacity]Key = undefined,
pending: std.StaticBitSet(capacity) = .initEmpty(),
order: [capacity]u8 = undefined,
head: u8 = 0,
len: usize = 0,
queued: bool = false,
pointer_finished: bool = false,

/// Keeps the latest release while ordinary admission is closed until recovery.
/// Example: `recovery.retain(key);`.
pub fn retain(recovery: *Recovery, key: Key) void {
    const index = key.physical.?.value - 1;
    std.debug.assert(index < capacity and key.phase == .release);
    recovery.keys[index] = key;
    if (recovery.pending.isSet(index)) {
        return;
    }

    recovery.order[(@as(usize, recovery.head) + recovery.len) % capacity] = @intCast(index);
    recovery.len += 1;
    recovery.pending.set(index);
}

pub fn next(recovery: *const Recovery) ?Key {
    if (recovery.len == 0) {
        return null;
    }

    return recovery.keys[recovery.order[recovery.head]];
}

pub fn finish(recovery: *Recovery, key: Key) void {
    recovery.pending.unset(key.physical.?.value - 1);
    recovery.head +%= 1;
    recovery.len -= 1;
}
