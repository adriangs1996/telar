const core = @import("telar-core");
const OwnedRename = @This();

request_id: core.RequestId,
location: core.TabLocation,
label: [core.max_tab_label_bytes]u8 = undefined,
len: u8,

pub fn slice(self: *const OwnedRename) []const u8 {
    return self.label[0..self.len];
}
