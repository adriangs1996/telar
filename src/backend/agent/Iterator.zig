const Agents = @import("Agents.zig");
const Agent = @import("Agent.zig");
const Iterator = @This();

repository: *Agents,
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
pub fn next(self: *Iterator) ?*Agent {
    self.current_index = null;

    while (self.next_index < self.repository.slots.len) {
        const index = self.next_index;
        self.next_index += 1;

        if (self.repository.occupiedAt(index)) {
            self.current_index = index;
            return &self.repository.slots[index].?;
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
pub fn removeCurrent(self: *Iterator) bool {
    const index = self.current_index orelse return false;

    if (!self.repository.occupiedAt(index)) {
        self.current_index = null;
        return false;
    }

    self.repository.release(index);
    self.current_index = null;
    return true;
}
