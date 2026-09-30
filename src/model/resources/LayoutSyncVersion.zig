const core = @import("telar-core");
const TabVersion = @import("TabVersion.zig");
const std = @import("std");
const Tabs = @import("../workspace/Tabs.zig");
const LayoutSyncVersion = @This();

chrome: u64,
active_tab: core.TabLocation,
tabs: [Tabs.capacity]TabVersion = undefined,
tab_count: u8 = 0,

pub fn eql(self: *const LayoutSyncVersion, right: *const LayoutSyncVersion) bool {
    if (self.chrome != right.chrome or
        !std.meta.eql(self.active_tab, right.active_tab) or
        self.tab_count != right.tab_count)
    {
        return false;
    }
    for (self.tabs[0..self.tab_count], right.tabs[0..right.tab_count]) |left_tab, right_tab| {
        if (!std.meta.eql(left_tab, right_tab)) {
            return false;
        }
    }

    return true;
}
