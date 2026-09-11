const RequestIdType = @import("telar-core").RequestId;
const PaneIdType = @import("telar-core").PaneId;
const max_search_needle_bytes_module = @import("telar-core").max_search_needle_bytes;
const SearchPaneType = @import("telar-core").SearchPane;
const OwnedSearch = @This();

request_id: RequestIdType,
pane_id: PaneIdType,
needle: [max_search_needle_bytes_module]u8 = undefined,
needle_len: u8 = 0,

pub fn view(value: *const OwnedSearch) SearchPaneType {
    return .{
        .request_id = value.request_id,
        .pane_id = value.pane_id,
        .needle = value.needle[0..value.needle_len],
    };
}
