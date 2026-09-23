const core = @import("telar-core");
const close_tab = @import("close_tab.zig");
const ApplyTabRemoval = @This();

location: core.TabLocation,
workspace_removed: bool,
previous_workspace: ?core.WorkspaceId,
trigger: close_tab.RemovalTrigger,
