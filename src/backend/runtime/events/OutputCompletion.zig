const PaneKey = @import("../../pane/PaneKey.zig");
const Completion = @This();

pane: PaneKey,
result: anyerror!u16,
