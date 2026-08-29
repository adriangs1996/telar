//! Bounded in-memory repository for agent aggregates.
//!
//! This type owns only collection mechanics. It does not interpret
//! observations, mutate agent lifecycle state, or publish projections.

const std = @import("std");
const core = @import("telar-core");
const Agent = @import("agent.zig");
const pane_mod = @import("../pane/root.zig");
const types = @import("types.zig");

const schema = core.schema;
const Identity = types.Identity;
const PaneKey = pane_mod.PaneKey;
const max_records = types.max_records;

pub const Repository = struct {
    slots: [max_records]?Agent = @splat(null),

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
    pub fn find(repository: *Repository, key: PaneKey) ?*Agent {
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
    pub fn findConst(repository: *const Repository, key: PaneKey) ?*const Agent {
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
    pub fn remove(repository: *Repository, key: PaneKey) bool {
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
};

fn testIdentity(id: u32, generation: u64) !Identity {
    return .{
        .key = .{ .id = try schema.id.pane(id), .generation = generation },
        .process_id = id,
        .session_id = .{@as(u8, @intCast(id))} ** 16,
    };
}

test "an empty repository has no matches removals or iteration results" {
    var repository: Repository = .{};
    const missing = (try testIdentity(1, 1)).key;

    try std.testing.expect(repository.find(missing) == null);
    try std.testing.expect(repository.findConst(missing) == null);
    try std.testing.expect(!repository.remove(missing));

    var iterator = repository.iterator();
    try std.testing.expect(iterator.next() == null);
    try std.testing.expect(!iterator.removeCurrent());

    var const_iterator = repository.constIterator();
    try std.testing.expect(const_iterator.next() == null);
}

test "insert stores and find returns the same aggregate" {
    var repository: Repository = .{};
    const identity = try testIdentity(1, 1);
    const inserted = repository.insert(Agent.init(identity)) orelse return error.MissingInsertedAgent;

    try std.testing.expect(inserted.matches(identity.key));
    try std.testing.expect(repository.find(identity.key) == inserted);
    try std.testing.expect(repository.findConst(identity.key).?.matches(identity.key));
}

test "pane generations are independent repository identities" {
    var repository: Repository = .{};
    const first = try testIdentity(1, 1);
    const second = try testIdentity(1, 2);

    _ = repository.insert(Agent.init(first)) orelse return error.MissingFirstGeneration;
    try std.testing.expect(repository.find(second.key) == null);
    _ = repository.insert(Agent.init(second)) orelse return error.MissingSecondGeneration;

    try std.testing.expect(repository.find(first.key) != null);
    try std.testing.expect(repository.find(second.key) != null);
}

test "insert rejects duplicate pane generations without consuming capacity" {
    var repository: Repository = .{};
    const identity = try testIdentity(1, 1);

    _ = repository.insert(Agent.init(identity)) orelse return error.MissingInsertedAgent;
    try std.testing.expect(repository.insert(Agent.init(identity)) == null);

    var iterator = repository.constIterator();
    var count: usize = 0;
    while (iterator.next() != null) {
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 1), count);
}

test "insert rejects overflow without losing stored aggregates" {
    var repository: Repository = .{};

    for (0..max_records) |index| {
        const identity = try testIdentity(@intCast(index + 1), 1);
        _ = repository.insert(Agent.init(identity)) orelse return error.RepositoryFilledEarly;
    }

    const overflow = try testIdentity(@intCast(max_records + 1), 1);
    try std.testing.expect(repository.insert(Agent.init(overflow)) == null);

    for (0..max_records) |index| {
        const identity = try testIdentity(@intCast(index + 1), 1);
        try std.testing.expect(repository.find(identity.key) != null);
    }
}

test "remove deletes only the exact pane generation and permits slot reuse" {
    var repository: Repository = .{};
    const first = try testIdentity(1, 1);
    const second = try testIdentity(1, 2);
    const replacement = try testIdentity(2, 1);

    _ = repository.insert(Agent.init(first)) orelse return error.MissingFirstGeneration;
    _ = repository.insert(Agent.init(second)) orelse return error.MissingSecondGeneration;
    try std.testing.expect(repository.remove(first.key));
    try std.testing.expect(!repository.remove(first.key));
    try std.testing.expect(repository.find(first.key) == null);
    try std.testing.expect(repository.find(second.key) != null);

    _ = repository.insert(Agent.init(replacement)) orelse return error.SlotWasNotReusable;
    try std.testing.expect(repository.find(replacement.key) != null);
}

test "mutable iteration can remove only its current aggregate" {
    var repository: Repository = .{};
    const first = try testIdentity(1, 1);
    const second = try testIdentity(2, 1);

    _ = repository.insert(Agent.init(first)) orelse return error.MissingFirstAgent;
    _ = repository.insert(Agent.init(second)) orelse return error.MissingSecondAgent;

    var iterator = repository.iterator();
    try std.testing.expect(iterator.next().?.matches(first.key));
    try std.testing.expect(iterator.removeCurrent());
    try std.testing.expect(!iterator.removeCurrent());
    try std.testing.expect(iterator.next().?.matches(second.key));
    try std.testing.expect(iterator.removeCurrent());
    try std.testing.expect(iterator.next() == null);
    try std.testing.expect(!iterator.removeCurrent());

    try std.testing.expect(repository.find(first.key) == null);
    try std.testing.expect(repository.find(second.key) == null);
}
