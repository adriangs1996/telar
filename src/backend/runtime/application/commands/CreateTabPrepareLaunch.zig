const PrepareLaunch = @This();
const source_namespace = @import("create_tab.zig");
workspace: source_namespace.schema.WorkspaceLocation,
launch: source_namespace.schema.LaunchView,
