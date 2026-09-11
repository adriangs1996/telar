const RepositoryType = @import("Repository.zig");
const Agent = @import("Agent.zig");
const Iterator = @This();

repository: *RepositoryType,
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
