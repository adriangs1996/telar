/// Stable response borrowed from the queue until completion is handled.
const Write = @This();
const source_namespace = @import("response.zig");
io: source_namespace.Io,
pane: *source_namespace.Pane,
bytes: []const u8,
