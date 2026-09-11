const std = @import("std");
const PaneType = @import("../../../../pane/Pane.zig");
/// Stable response borrowed from the queue until completion is handled.
const Write = @This();

io: std.Io,
pane: *PaneType,
bytes: []const u8,
