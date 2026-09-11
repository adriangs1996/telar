const id = @import("../id.zig");
const SearchMatchIterator = @import("SearchMatchIterator.zig");
const PaneMatchesView = @This();

request_id: id.RequestId,
pane_id: id.PaneId,
truncated: bool,
match_count: u16,
encoded_matches: []const u8,

pub fn matches(view: PaneMatchesView) SearchMatchIterator {
    return .{ .decoder = .init(view.encoded_matches), .remaining = view.match_count };
}
