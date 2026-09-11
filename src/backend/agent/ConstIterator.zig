const RepositoryType = @import("Repository.zig");
const Agent = @import("Agent.zig");
const ConstIterator = @This();

repository: *const RepositoryType,
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
