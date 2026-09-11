const Completion = @This();
const source_namespace = @import("output.zig");
pane: source_namespace.PaneKey,
result: anyerror!u16,
