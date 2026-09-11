const ApplyTabRemoval = @This();
const source_namespace = @import("close_tab.zig");
location: source_namespace.schema.TabLocation,
workspace_removed: bool,
previous_workspace: ?source_namespace.schema.WorkspaceId,
trigger: source_namespace.RemovalTrigger,
