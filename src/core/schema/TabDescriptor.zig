const id = @import("id.zig");
const TabDescriptor = @This();

tab_id: id.TabId,
position: u16,
pane_count: u16,
label: []const u8,
