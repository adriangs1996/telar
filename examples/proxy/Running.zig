const std = @import("std");
/// A command between its OSC 133 C and D markers.
const Running = @This();

id: i64,
started_at: std.Io.Timestamp,
