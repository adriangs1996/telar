const core = @import("telar-core");
const OpenPane = @This();

target: core.PaneTarget,
size: core.TerminalSize,
launch: ?core.LaunchView,
