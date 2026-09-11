const Repository = @This();
const source_namespace = @import("repository_support.zig");
const Agent = @import("Agent.zig");
slots: [source_namespace.max_records]?Agent = @splat(null),

pub const Iterator = struct {
    repository: *Repository,
    next_index: usize = 0,
    current_index: ?usize = null,

    /// Returns each stored aggregate once in repository order.
    ///
    /// ```zig
    /// var iterator = repository.iterator();
    /// while (iterator.next()) |agent| {
    ///     inspect(agent);
    /// }
    /// ```
    pub fn next(cursor: *Iterator) ?*Agent {
        cursor.current_index = null;

        while (cursor.next_index < cursor.repository.slots.len) {
            const index = cursor.next_index;
            cursor.next_index += 1;

            if (cursor.repository.slots[index]) |*agent| {
                cursor.current_index = index;
                return agent;
            }
        }

        return null;
    }

    /// Removes the aggregate returned by the latest `next` call.
    ///
    /// ```zig
    /// if (iterator.next()) |_| {
    ///     _ = iterator.removeCurrent();
    /// }
    /// ```
    pub fn removeCurrent(cursor: *Iterator) bool {
        const index = cursor.current_index orelse return false;

        if (cursor.repository.slots[index] == null) {
            cursor.current_index = null;
            return false;
        }

        cursor.repository.slots[index] = null;
        cursor.current_index = null;
        return true;
    }
};

pub const ConstIterator = struct {
    repository: *const Repository,
    next_index: usize = 0,

    /// Returns immutable access to each stored aggregate once.
    ///
    /// ```zig
    /// var iterator = repository.constIterator();
    /// while (iterator.next()) |agent| {
    ///     publish(agent.snapshot());
    /// }
    /// ```
    pub fn next(cursor: *ConstIterator) ?*const Agent {
        while (cursor.next_index < cursor.repository.slots.len) {
            const index = cursor.next_index;
            cursor.next_index += 1;

            if (cursor.repository.slots[index]) |*agent| {
                return agent;
            }
        }

        return null;
    }
};

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
pub fn find(repository: *Repository, key: source_namespace.PaneKey) ?*Agent {
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
pub fn findConst(repository: *const Repository, key: source_namespace.PaneKey) ?*const Agent {
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
pub fn remove(repository: *Repository, key: source_namespace.PaneKey) bool {
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
