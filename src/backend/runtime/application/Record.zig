const core = @import("telar-core");
const StoredTab = @import("StoredTab.zig");
const Record = @This();

identity: core.ClientIdentity = .invalid,
last_used: u64 = 0,
sidebar_visible: bool = true,
sidebar_width: u16 = 0,
workspace_list_collapsed: bool = false,
active_tab: core.TabLocation = undefined,
tabs: [core.max_client_layout_tabs]StoredTab = undefined,
tab_count: u8 = 0,
