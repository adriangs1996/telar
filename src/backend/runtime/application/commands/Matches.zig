const max_search_matches_module = @import("telar-core").max_search_matches;
const SearchMatchType = @import("telar-core").SearchMatch;
const Matches = @This();

items: [max_search_matches_module]SearchMatchType = undefined,
count: u8 = 0,
truncated: bool = false,

pub fn slice(matches: *const Matches) []const SearchMatchType {
    return matches.items[0..matches.count];
}
