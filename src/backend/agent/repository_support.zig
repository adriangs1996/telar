//! Bounded in-memory repository for agent aggregates.
//!
//! This type owns only collection mechanics. It does not interpret
//! observations, mutate agent lifecycle state, or publish projections.

const std = @import("std");
const core = @import("telar-core");
const Agent = @import("Agent.zig");
const pane_mod = @import("../pane/root.zig");
const types = @import("types.zig");

const schema = core.schema;
const Identity = types.Identity;
pub const PaneKey = pane_mod.PaneKey;
pub const max_records = types.max_records;

pub const Repository = @import("Repository.zig");

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
