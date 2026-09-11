const OwnedRename = @This();
const source_namespace = @import("outbox_support.zig");
request_id: source_namespace.schema.RequestId,
location: source_namespace.schema.TabLocation,
label: [source_namespace.schema.max_tab_label_bytes]u8 = undefined,
len: u8,

pub fn slice(rename: *const OwnedRename) []const u8 {
    return rename.label[0..rename.len];
}
