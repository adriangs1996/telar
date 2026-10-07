const core = @import("telar-core");
const Matches = @This();

// SAFETY: pane_search fills items through cursor.ordered before recording count; slice exposes only that prefix.
items: [core.max_search_matches]core.SearchMatch = undefined,
count: u16 = 0,
truncated: bool = false,

pub fn slice(self: *const Matches) []const core.SearchMatch {
    return self.items[0..self.count];
}
