const Matches = @This();
const source_namespace = @import("search_pane.zig");
items: [source_namespace.schema.max_search_matches]source_namespace.schema.SearchMatch = undefined,
count: u8 = 0,
truncated: bool = false,

pub fn slice(matches: *const Matches) []const source_namespace.schema.SearchMatch {
    return matches.items[0..matches.count];
}
