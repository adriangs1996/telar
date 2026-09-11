const IteratorType = @import("Iterator.zig");
const ConstIteratorType = @import("ConstIterator.zig");
const max_agent_snapshot_entries = @import("telar-core").max_agent_snapshot_entries;
const Agent = @import("Agent.zig");
const PaneKeyType = @import("../pane/PaneKey.zig");
pub const Repository = @This();

slots: [max_agent_snapshot_entries]?Agent = @splat(null),

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

    for (&repository.slots) |*slot| {
        if (slot.* != null) {
            continue;
        }

        slot.* = candidate;
        return &slot.*.?;
    }

    return null;
}

/// Finds the mutable aggregate for one exact pane generation.
///
/// ```zig
/// const agent = repository.find(pane_key) orelse return;
/// ```
pub fn find(repository: *Repository, key: PaneKeyType) ?*Agent {
    for (&repository.slots) |*slot| {
        const agent = if (slot.*) |*value| value else continue;

        if (agent.matches(key)) {
            return agent;
        }
    }

    return null;
}

/// Finds the immutable aggregate for one exact pane generation.
///
/// ```zig
/// const agent = repository.findConst(pane_key) orelse return;
/// ```
pub fn findConst(repository: *const Repository, key: PaneKeyType) ?*const Agent {
    for (&repository.slots) |*slot| {
        const agent = if (slot.*) |*value| value else continue;

        if (agent.matches(key)) {
            return agent;
        }
    }

    return null;
}

/// Removes one exact pane generation without applying lifecycle policy.
///
/// ```zig
/// _ = repository.remove(pane_key);
/// ```
pub fn remove(repository: *Repository, key: PaneKeyType) bool {
    for (&repository.slots) |*slot| {
        const agent = if (slot.*) |*value| value else continue;

        if (!agent.matches(key)) {
            continue;
        }

        slot.* = null;
        return true;
    }

    return false;
}

/// Creates a mutable iterator over the current repository contents.
///
/// ```zig
/// var iterator = repository.iterator();
/// ```
pub fn iterator(repository: *Repository) IteratorType {
    return .{ .repository = repository };
}

/// Creates an immutable iterator over the current repository contents.
///
/// ```zig
/// var iterator = repository.constIterator();
/// ```
pub fn constIterator(repository: *const Repository) ConstIteratorType {
    return .{ .repository = repository };
}
