const core = @import("telar-core");
const TabVersion = @import("TabVersion.zig");
const std = @import("std");
const LayoutSyncVersion = @This();

chrome: u64,
active_tab: core.TabLocation,
tabs: [core.max_client_layout_tabs]TabVersion = undefined,
tab_count: u8 = 0,

pub fn eql(left: *const LayoutSyncVersion, right: *const LayoutSyncVersion) bool {
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
