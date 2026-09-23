const core = @import("telar-core");
const Matches = @This();

items: [core.max_search_matches]core.SearchMatch = undefined,
count: u8 = 0,
truncated: bool = false,

pub fn slice(self: *const Matches) []const core.SearchMatch {
    return self.items[0..self.count];
}
