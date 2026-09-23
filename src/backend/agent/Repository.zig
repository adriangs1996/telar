const std = @import("std");
const core = @import("telar-core");
const Agent = @import("Agent.zig");
const PaneKeyType = @import("../pane/PaneKey.zig");
pub const Repository = @This();

pub const capacity = core.max_agent_snapshot_entries;
const Occupancy = std.bit_set.IntegerBitSet(capacity);

/// Aggregates are several KiB each. Lookups run on every PTY ingest, so they
/// probe `index` by pane id and check the generation in the dense `keys`
/// copy instead of touching an aggregate. A pane id belongs to one pane
/// generation at a time, so at most one aggregate exists per pane id. An
/// aggregate's key never changes after insertion, and every insertion and
/// removal updates all four fields together.
slots: [capacity]?Agent = @splat(null),
keys: [capacity]PaneKeyType = undefined,
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
pub fn insert(repository: *Repository, candidate: Agent) ?*Agent {
    const key = candidate.paneKey();
    if (repository.index.get(core.raw(key.id)) != null) {
        return null;
    }

    var free = repository.occupied.complement().iterator(.{});
    if (free.next()) |slot| {
        repository.slots[slot] = candidate;
        repository.keys[slot] = key;
        repository.occupied.set(slot);
        repository.index.put(core.raw(key.id), slot);
        return &repository.slots[slot].?;
    }

    return null;
}

/// Finds the mutable aggregate for one exact pane generation.
///
/// ```zig
/// const agent = repository.find(pane_key) orelse return;
/// ```
pub fn find(repository: *Repository, key: PaneKeyType) ?*Agent {
    const index = repository.indexOf(key) orelse return null;
    return &repository.slots[index].?;
}

/// Finds the immutable aggregate for one exact pane generation.
///
/// ```zig
/// const agent = repository.findConst(pane_key) orelse return;
/// ```
pub fn findConst(repository: *const Repository, key: PaneKeyType) ?*const Agent {
    const index = repository.indexOf(key) orelse return null;
    return &repository.slots[index].?;
}

/// Removes one exact pane generation without applying lifecycle policy.
///
/// ```zig
/// _ = repository.remove(pane_key);
/// ```
pub fn remove(repository: *Repository, key: PaneKeyType) bool {
    const index = repository.indexOf(key) orelse return false;
    repository.release(index);
    return true;
}

/// Whether a slot holds an aggregate, without reading the aggregate.
pub fn occupiedAt(repository: *const Repository, index: usize) bool {
    return repository.occupied.isSet(index);
}

/// Empties one occupied slot. Iterators remove their current aggregate here.
pub fn release(repository: *Repository, index: usize) void {
    std.debug.assert(repository.occupied.isSet(index));
    repository.index.remove(core.raw(repository.keys[index].id));
    repository.slots[index] = null;
    repository.occupied.unset(index);
}

fn indexOf(repository: *const Repository, key: PaneKeyType) ?usize {
    const slot = repository.index.get(core.raw(key.id)) orelse return null;
    if (repository.keys[slot].generation != key.generation) {
        return null;
    }

    std.debug.assert(repository.slots[slot].?.matches(key));
    return slot;
}

/// Creates a mutable iterator over the current repository contents.
///
/// ```zig
/// var iterator = repository.iterator();
/// ```
pub fn iterator(repository: *Repository) Iterator {
    return .{ .repository = repository };
}

/// Creates an immutable iterator over the current repository contents.
///
/// ```zig
/// var iterator = repository.constIterator();
/// ```
pub fn constIterator(repository: *const Repository) ConstIterator {
    return .{ .repository = repository };
}
