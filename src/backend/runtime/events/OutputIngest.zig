const std = @import("std");
const Pane = @import("../../pane/Pane.zig");
/// Output-buffer borrow handed to the VT ingest actor.
const Ingest = @This();

io: std.Io,
pane: *Pane,
bytes: []const u8,
