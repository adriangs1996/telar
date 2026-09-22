const core = @import("telar-core");
const LaunchPane = @This();

location: core.TabLocation,
size: core.TerminalSize,
launch: core.LaunchView,
launch_cwd: []const u8,
workspace_path: []const u8,

kind: core.PaneKind = .terminal,
