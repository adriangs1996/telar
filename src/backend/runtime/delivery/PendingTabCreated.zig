const PendingTabCreated = @This();
const source_namespace = @import("response_queue.zig");
request_id: source_namespace.schema.RequestId,
location: source_namespace.schema.TabLocation,
position: u16,
label: [source_namespace.schema.max_tab_label_bytes]u8,
label_len: u8,
root_pane_id: source_namespace.schema.PaneId,

pub fn labelSlice(created: *const PendingTabCreated) []const u8 {
    return created.label[0..created.label_len];
}
