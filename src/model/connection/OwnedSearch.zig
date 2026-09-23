const core = @import("telar-core");
const OwnedSearch = @This();

request_id: core.RequestId,
pane_id: core.PaneId,
needle: [core.max_search_needle_bytes]u8 = undefined,
needle_len: u8 = 0,

pub fn view(self: *const OwnedSearch) core.SearchPane {
    return .{
        .request_id = self.request_id,
        .pane_id = self.pane_id,
        .needle = self.needle[0..self.needle_len],
    };
}
