const PaneMatchesView = @This();
const source_namespace = @import("pane.zig");
const SearchMatchIterator = @import("SearchMatchIterator.zig");
request_id: source_namespace.RequestId,
pane_id: source_namespace.PaneId,
truncated: bool,
match_count: u16,
encoded_matches: []const u8,

pub fn matches(view: PaneMatchesView) SearchMatchIterator {
    return .{ .decoder = .init(view.encoded_matches), .remaining = view.match_count };
}
