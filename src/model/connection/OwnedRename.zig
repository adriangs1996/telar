const core = @import("telar-core");
const OwnedRename = @This();

request_id: core.RequestId,
location: core.TabLocation,
label: [core.max_tab_label_bytes]u8 = undefined,
len: u8,

pub fn slice(rename: *const OwnedRename) []const u8 {
    return rename.label[0..rename.len];
}
