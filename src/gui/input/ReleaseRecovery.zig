//! Native key identities are keycode + 1, bounded by both hosts' 256-key tables.
const std = @import("std");
const Key = @import("KeyInput.zig");
const Recovery = @This();

pub const capacity = 256;
keys: [capacity]Key = undefined,
pending: std.StaticBitSet(capacity) = .initEmpty(),
order: [capacity]u8 = undefined,
head: u8 = 0,
len: usize = 0,
queued: bool = false,

/// Keeps the latest release while ordinary admission is closed until recovery.
/// Example: `recovery.retain(key);`.
pub fn retain(self: *Recovery, key: Key) void {
    const index = key.physical.?.value - 1;
    std.debug.assert(index < capacity and key.phase == .release);
    self.keys[index] = key;
    if (self.pending.isSet(index)) {
        return;
    }

    self.order[(@as(usize, self.head) + self.len) % capacity] = @intCast(index);
    self.len += 1;
    self.pending.set(index);
}

pub fn next(self: *const Recovery) ?Key {
    if (self.len == 0) {
        return null;
    }

    return self.keys[self.order[self.head]];
}

pub fn finish(self: *Recovery, key: Key) void {
    self.pending.unset(key.physical.?.value - 1);
    self.head +%= 1;
    self.len -= 1;
}
