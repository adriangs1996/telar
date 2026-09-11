const RequestIdType = @import("telar-core").RequestId;
const TabLocationType = @import("telar-core").TabLocation;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const OwnedRename = @This();

request_id: RequestIdType,
location: TabLocationType,
label: [max_tab_label_bytes_module]u8 = undefined,
len: u8,

pub fn slice(rename: *const OwnedRename) []const u8 {
    return rename.label[0..rename.len];
}
