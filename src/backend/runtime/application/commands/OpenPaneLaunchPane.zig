const LaunchPane = @This();
const source_namespace = @import("open_pane.zig");
location: source_namespace.schema.TabLocation,
size: source_namespace.schema.TerminalSize,
launch: source_namespace.schema.LaunchView,
launch_cwd: []const u8,
workspace_path: []const u8,
