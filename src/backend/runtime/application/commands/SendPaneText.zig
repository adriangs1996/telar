const PaneKeyType = @import("../../../pane/PaneKey.zig");
const PaneTextModeType = @import("telar-core").PaneTextMode;
const SendPaneText = @This();

pane: PaneKeyType,
mode: PaneTextModeType,
text: []const u8,
