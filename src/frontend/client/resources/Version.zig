const TabLocationType = @import("telar-core").TabLocation;
const max_client_layout_tabs_module = @import("telar-core").max_client_layout_tabs;
const TabVersion = @import("TabVersion.zig");
const std = @import("std");
const Version = @This();

chrome: u64,
active_tab: TabLocationType,
tabs: [max_client_layout_tabs_module]TabVersion = undefined,
tab_count: u8 = 0,

pub fn eql(left: *const Version, right: *const Version) bool {
    if (left.chrome != right.chrome or
        !std.meta.eql(left.active_tab, right.active_tab) or
        left.tab_count != right.tab_count)
    {
        return false;
    }
    for (left.tabs[0..left.tab_count], right.tabs[0..right.tab_count]) |left_tab, right_tab| {
        if (!std.meta.eql(left_tab, right_tab)) {
            return false;
        }
    }

    return true;
}
