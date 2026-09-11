const OwnedSearch = @This();
const source_namespace = @import("outbox_support.zig");
request_id: source_namespace.schema.RequestId,
pane_id: source_namespace.schema.PaneId,
needle: [source_namespace.schema.max_search_needle_bytes]u8 = undefined,
needle_len: u8 = 0,

pub fn view(value: *const OwnedSearch) source_namespace.schema.SearchPane {
    return .{
        .request_id = value.request_id,
        .pane_id = value.pane_id,
        .needle = value.needle[0..value.needle_len],
    };
}
