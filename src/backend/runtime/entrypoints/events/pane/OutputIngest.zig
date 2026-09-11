const std = @import("std");
const PaneType = @import("../../../../pane/Pane.zig");
/// Output-buffer borrow handed to the VT ingest actor.
const Ingest = @This();

io: std.Io,
pane: *PaneType,
bytes: []const u8,
