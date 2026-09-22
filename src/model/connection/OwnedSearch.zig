const core = @import("telar-core");
const OwnedSearch = @This();

request_id: core.RequestId,
pane_id: core.PaneId,
needle: [core.max_search_needle_bytes]u8 = undefined,
needle_len: u8 = 0,

pub fn view(value: *const OwnedSearch) core.SearchPane {
    return .{
        .request_id = value.request_id,
        .pane_id = value.pane_id,
        .needle = value.needle[0..value.needle_len],
    };
}
