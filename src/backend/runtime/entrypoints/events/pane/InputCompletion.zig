const Completion = @This();
const source_namespace = @import("input.zig");
pane: source_namespace.PaneKey,
started_ns: u64,
result: anyerror!void,
