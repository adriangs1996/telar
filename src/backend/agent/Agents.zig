//! The runtime's agents table: one aggregate per pane generation that has
//! agent evidence, indexed by pane id.
const std = @import("std");
const core = @import("telar-core");
const Agent = @import("Agent.zig");
const PaneKey = @import("../pane/PaneKey.zig");
const Agents = @This();

pub const capacity = core.max_agent_snapshot_entries;
const Occupancy = std.bit_set.IntegerBitSet(capacity);

/// Aggregates are several KiB each. Lookups run on every PTY ingest, so they
/// probe `index` by pane id and check the generation in the dense `keys`
/// copy instead of touching an aggregate. A pane id belongs to one pane
/// generation at a time, so at most one aggregate exists per pane id. An
/// aggregate's key never changes after insertion, and every insertion and
/// removal updates all four fields together.
slots: [capacity]?Agent = @splat(null),
keys: [capacity]PaneKey = undefined,
occupied: Occupancy = .initEmpty(),
index: core.GenericSlotIndex(2 * capacity) = .{},

pub const Iterator = @import("Iterator.zig");

pub const ConstIterator = @import("ConstIterator.zig");

/// Inserts one aggregate unless its pane id already has one or the
/// repository has reached its fixed capacity.
///
/// ```zig
/// const stored = repository.insert(Agent.init(identity)) orelse return;
/// ```
pub fn insert(self: *Agents, candidate: Agent) ?*Agent {
    const key = candidate.paneKey();
    if (self.index.get(core.raw(key.id)) != null) {
        return null;
    }

    var free = self.occupied.complement().iterator(.{});
    if (free.next()) |slot| {
        self.slots[slot] = candidate;
        self.keys[slot] = key;
        self.occupied.set(slot);
        self.index.put(core.raw(key.id), slot);
        return &self.slots[slot].?;
    }

    return null;
}

/// Finds the mutable aggregate for one exact pane generation.
///
/// ```zig
/// const agent = repository.find(pane_key) orelse return;
/// ```
pub fn find(self: *Agents, key: PaneKey) ?*Agent {
    const index = self.indexOf(key) orelse return null;
    return &self.slots[index].?;
}

/// Finds the immutable aggregate for one exact pane generation.
///
/// ```zig
/// const agent = repository.findConst(pane_key) orelse return;
/// ```
pub fn findConst(self: *const Agents, key: PaneKey) ?*const Agent {
    const index = self.indexOf(key) orelse return null;
    return &self.slots[index].?;
}

/// Removes one exact pane generation without applying lifecycle policy.
///
/// ```zig
/// _ = repository.remove(pane_key);
/// ```
pub fn remove(self: *Agents, key: PaneKey) bool {
    const index = self.indexOf(key) orelse return false;
    self.release(index);
    return true;
}

/// Whether a slot holds an aggregate, without reading the aggregate.
pub fn occupiedAt(self: *const Agents, index: usize) bool {
    return self.occupied.isSet(index);
}

/// Empties one occupied slot. Iterators remove their current aggregate here.
pub fn release(self: *Agents, index: usize) void {
    std.debug.assert(self.occupied.isSet(index));
    self.index.remove(core.raw(self.keys[index].id));
    self.slots[index] = null;
    self.occupied.unset(index);
}

fn indexOf(self: *const Agents, key: PaneKey) ?usize {
    const slot = self.index.get(core.raw(key.id)) orelse return null;
    if (self.keys[slot].generation != key.generation) {
        return null;
    }

    std.debug.assert(self.slots[slot].?.matches(key));
    return slot;
}

/// Creates a mutable iterator over the current repository contents.
///
/// ```zig
/// var iterator = repository.iterator();
/// ```
pub fn iterator(self: *Agents) Iterator {
    return .{ .repository = self };
}

/// Creates an immutable iterator over the current repository contents.
///
/// ```zig
/// var iterator = repository.constIterator();
/// ```
pub fn constIterator(self: *const Agents) ConstIterator {
    return .{ .repository = self };
}
