const std = @import("std");
const Pane = @import("../../pane/Pane.zig");
/// Stable input borrowed from a pane until its completion event is handled.
const Write = @This();

io: std.Io,
pane: *Pane,
bytes: []const u8,
started_ns: u64,
