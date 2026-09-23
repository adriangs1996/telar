const PaneKey = @import("../../pane/PaneKey.zig");
const Completion = @This();

pane: PaneKey,
started_ns: u64,
result: anyerror!void,
