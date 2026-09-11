const PaneLaunchedType = @import("../../../pane/PaneLaunched.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const PrepareView = @This();

pane: PaneLaunchedType,
size: TerminalSizeType,
