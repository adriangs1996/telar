const core = @import("telar-core");
const TabRemovalAbsence = @import("../types/TabRemovalAbsence.zig").TabRemovalAbsence;
const StaleTabRemoval = @This();

location: core.TabLocation,
absence: TabRemovalAbsence,
workspace_revision: u64,
tabs_revision: u64,
active_tab_revision: u64,
panes_revision: u64,
copy_revision: u64,
