/// Stable input borrowed from a pane until its completion event is handled.
const Write = @This();
const source_namespace = @import("input.zig");
io: source_namespace.Io,
pane: *source_namespace.Pane,
bytes: []const u8,
started_ns: u64,
