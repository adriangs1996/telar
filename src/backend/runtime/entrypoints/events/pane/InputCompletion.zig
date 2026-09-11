const PaneKeyType = @import("../../../../pane/PaneKey.zig");
const Completion = @This();

pane: PaneKeyType,
started_ns: u64,
result: anyerror!void,
