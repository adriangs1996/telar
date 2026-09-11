const RequestIdType = @import("telar-core").RequestId;
const TabLocationType = @import("telar-core").TabLocation;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const PendingTabRenamed = @This();

request_id: RequestIdType,
location: TabLocationType,
label: [max_tab_label_bytes_module]u8,
label_len: u8,

pub fn labelSlice(renamed: *const PendingTabRenamed) []const u8 {
    return renamed.label[0..renamed.label_len];
}
