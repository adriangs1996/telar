//! A `find_paths` query copied out of the receive buffer, so it can wait for
//! the index and cross to a query worker without borrowing.

const core = @import("telar-core");
const OwnedQuery = @This();

request_id: core.RequestId = @enumFromInt(1),
text: [core.max_path_query_bytes]u8 = undefined,
text_len: u8 = 0,
kind: core.PathKindFilter = .any,
limit: u16 = core.max_path_results,

/// Copies a validated request. Example: `index.wanted = .init(request);`
pub fn init(request: core.FindPaths) OwnedQuery {
    var owned: OwnedQuery = .{
        .request_id = request.request_id,
        .text_len = @intCast(request.query.len),
        .kind = request.kind,
        .limit = request.limit,
    };
    @memcpy(owned.text[0..request.query.len], request.query);
    return owned;
}

pub fn textSlice(self: *const OwnedQuery) []const u8 {
    return self.text[0..self.text_len];
}
