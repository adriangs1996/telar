const PaneKeyType = @import("../../../../pane/PaneKey.zig");
const Completion = @This();

pane: PaneKeyType,
result: anyerror!void,
