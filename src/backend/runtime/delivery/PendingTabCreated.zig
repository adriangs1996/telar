const core = @import("telar-core");
const PendingTabCreated = @This();

request_id: core.RequestId,
location: core.TabLocation,
position: u16,
label: [core.max_tab_label_bytes]u8,
label_len: u8,
root_pane_id: core.PaneId,
kind: core.PaneKind = .terminal,
pane_generation: u64 = 0,

pub fn labelSlice(self: *const PendingTabCreated) []const u8 {
    return self.label[0..self.label_len];
}
