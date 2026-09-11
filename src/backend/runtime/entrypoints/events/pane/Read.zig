/// Output-read borrow handed to the runtime actor scheduler.
const Read = @This();
const source_namespace = @import("ingest.zig");
io: source_namespace.Io,
pane: *source_namespace.Pane,
