const RequestIdType = @import("telar-core").RequestId;
const TabLocationType = @import("telar-core").TabLocation;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const PaneIdType = @import("telar-core").PaneId;
const PendingTabCreated = @This();

request_id: RequestIdType,
location: TabLocationType,
position: u16,
label: [max_tab_label_bytes_module]u8,
label_len: u8,
root_pane_id: PaneIdType,

pub fn labelSlice(created: *const PendingTabCreated) []const u8 {
    return created.label[0..created.label_len];
}
