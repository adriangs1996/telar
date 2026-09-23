const std = @import("std");
const core = @import("telar-core");
const Agent = @import("Agent.zig");
const PaneKeyType = @import("../pane/PaneKey.zig");
pub const Repository = @This();

pub const capacity = core.max_agent_snapshot_entries;
const Occupancy = std.bit_set.IntegerBitSet(capacity);

/// Aggregates are several KiB each. Lookups run on every PTY ingest, so they
/// scan the dense `keys` copy and the `occupied` mask instead of touching one
/// aggregate per slot. An aggregate's key never changes after insertion, and
/// every insertion and removal updates all three fields together.
slots: [capacity]?Agent = @splat(null),
keys: [capacity]PaneKeyType = undefined,
occupied: Occupancy = .initEmpty(),

pub const Iterator = @import("Iterator.zig");

pub const ConstIterator = @import("ConstIterator.zig");

/// Inserts one aggregate unless its pane generation already exists or the
/// repository has reached its fixed capacity.
///
/// ```zig
/// const stored = repository.insert(Agent.init(identity)) orelse return;
/// ```
pub fn insert(repository: *Repository, candidate: Agent) ?*Agent {
    if (repository.find(candidate.paneKey()) != null) {
        return null;
    }

    var free = repository.occupied.complement().iterator(.{});
    if (free.next()) |index| {
        repository.slots[index] = candidate;
        repository.keys[index] = candidate.paneKey();
        repository.occupied.set(index);
        return &repository.slots[index].?;
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
    repository.slots[index] = null;
    repository.occupied.unset(index);
}

fn indexOf(repository: *const Repository, key: PaneKeyType) ?usize {
    var occupied = repository.occupied.iterator(.{});
    while (occupied.next()) |index| {
        const candidate = repository.keys[index];
        if (candidate.id == key.id and candidate.generation == key.generation) {
            std.debug.assert(repository.slots[index].?.matches(key));
            return index;
        }
    }

    return null;
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
