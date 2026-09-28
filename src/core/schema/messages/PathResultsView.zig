const id = @import("../id.zig");
const PathMatchIterator = @import("PathMatchIterator.zig");
const PathResultsView = @This();

request_id: id.RequestId,
root: []const u8,
scanned: u32,
complete: bool,
truncated: bool,
match_count: u16,
encoded_matches: []const u8,

pub fn matches(self: PathResultsView) PathMatchIterator {
    return .{
        .decoder = .init(self.encoded_matches),
        .remaining = self.match_count,
    };
}
