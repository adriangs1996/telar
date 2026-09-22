const core = @import("telar-core");
const data = @import("model");
const PendingLayoutRestore = @This();

location: core.TabLocation,
layout: data.WorkspaceLayout,
restore_saved_focus: bool = false,
