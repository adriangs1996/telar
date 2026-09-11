const TabLocationType = @import("telar-core").TabLocation;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const close_tab = @import("close_tab.zig");
const ApplyTabRemoval = @This();

location: TabLocationType,
workspace_removed: bool,
previous_workspace: ?WorkspaceIdType,
trigger: close_tab.RemovalTrigger,
