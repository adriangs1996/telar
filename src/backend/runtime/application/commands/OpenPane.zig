const PaneTargetType = @import("telar-core").PaneTarget;
const TerminalSizeType = @import("telar-core").TerminalSize;
const LaunchViewType = @import("telar-core").LaunchView;
const OpenPane = @This();

target: PaneTargetType,
size: TerminalSizeType,
launch: ?LaunchViewType,
