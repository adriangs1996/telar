const core = @import("telar-core");

previous: core.TabLocation,
created: core.TabLocation,
tabs_revision_before: u64,
active_tab_revision_before: u64,
copy_revision_before: u64,
copy_released: bool,
workspace_revision: u64,
tabs_revision: u64,
active_tab_revision: u64,
panes_revision: u64,
copy_revision: u64,
