const std = @import("std");
const Pane = @import("../../pane/Pane.zig");
/// Stable response borrowed from the queue until completion is handled.
const Write = @This();

io: std.Io,
pane: *Pane,
bytes: []const u8,
