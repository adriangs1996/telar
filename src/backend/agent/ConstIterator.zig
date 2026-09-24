const Agents = @import("Agents.zig");
const Agent = @import("Agent.zig");
const ConstIterator = @This();

repository: *const Agents,
next_index: usize = 0,

/// Returns immutable access to each stored aggregate once.
///
/// ```zig
/// var iterator = repository.constIterator();
/// while (iterator.next()) |agent| {
///     publish(agent.snapshot());
/// }
/// ```
pub fn next(self: *ConstIterator) ?*const Agent {
    while (self.next_index < self.repository.slots.len) {
        const index = self.next_index;
        self.next_index += 1;

        if (self.repository.occupiedAt(index)) {
            return &self.repository.slots[index].?;
        }
    }

    return null;
}
