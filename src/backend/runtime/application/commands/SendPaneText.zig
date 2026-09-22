const core = @import("telar-core");
const PaneKeyType = @import("../../../pane/PaneKey.zig");
const SendPaneText = @This();

pane: PaneKeyType,
mode: core.PaneTextMode,
text: []const u8,
