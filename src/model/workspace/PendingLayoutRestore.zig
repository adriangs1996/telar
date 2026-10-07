const core = @import("telar-core");
const data = @import("../model.zig");

location: core.TabLocation,
layout: data.WorkspaceLayout,
restore_saved_focus: bool = false,
