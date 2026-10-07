const core = @import("telar-core");
const OwnedRename = @This();

request_id: core.RequestId,
location: core.TabLocation,
// SAFETY: Outbox.pushRename copies the validated label before queueing this value; slice exposes only len bytes.
label: [core.max_tab_label_bytes]u8 = undefined,
len: u8,

pub fn slice(self: *const OwnedRename) []const u8 {
    return self.label[0..self.len];
}
