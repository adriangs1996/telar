const core = @import("telar-core");
const PendingTabRenamed = @This();

request_id: core.RequestId,
location: core.TabLocation,
label: [core.max_tab_label_bytes]u8,
label_len: u8,

pub fn labelSlice(renamed: *const PendingTabRenamed) []const u8 {
    return renamed.label[0..renamed.label_len];
}
