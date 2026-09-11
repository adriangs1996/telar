const TabDescriptor = @This();
const id = @import("id.zig");
tab_id: id.TabId,
position: u16,
pane_count: u16,
label: []const u8,
