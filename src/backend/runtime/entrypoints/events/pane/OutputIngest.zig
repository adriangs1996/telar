/// Output-buffer borrow handed to the VT ingest actor.
const Ingest = @This();
const source_namespace = @import("output.zig");
io: source_namespace.Io,
pane: *source_namespace.Pane,
bytes: []const u8,
