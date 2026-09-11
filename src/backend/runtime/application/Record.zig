const ClientIdentityType = @import("telar-core").ClientIdentity;
const TabLocationType = @import("telar-core").TabLocation;
const max_client_layout_tabs_module = @import("telar-core").max_client_layout_tabs;
const StoredTab = @import("StoredTab.zig");
const Record = @This();

identity: ClientIdentityType = .invalid,
last_used: u64 = 0,
sidebar_visible: bool = true,
sidebar_width: u16 = 0,
workspace_list_collapsed: bool = false,
active_tab: TabLocationType = undefined,
tabs: [max_client_layout_tabs_module]StoredTab = undefined,
tab_count: u8 = 0,
