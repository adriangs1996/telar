const TabLocationType = @import("telar-core").TabLocation;
const TerminalSizeType = @import("telar-core").TerminalSize;
const LaunchViewType = @import("telar-core").LaunchView;
const LaunchPane = @This();

location: TabLocationType,
size: TerminalSizeType,
launch: LaunchViewType,
launch_cwd: []const u8,
workspace_path: []const u8,
