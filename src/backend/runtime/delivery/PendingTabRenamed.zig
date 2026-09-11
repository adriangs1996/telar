const PendingTabRenamed = @This();
const source_namespace = @import("response_queue.zig");
request_id: source_namespace.schema.RequestId,
location: source_namespace.schema.TabLocation,
label: [source_namespace.schema.max_tab_label_bytes]u8,
label_len: u8,

pub fn labelSlice(renamed: *const PendingTabRenamed) []const u8 {
    return renamed.label[0..renamed.label_len];
}
