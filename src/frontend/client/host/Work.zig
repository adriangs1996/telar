const std = @import("std");
const Work = @This();

target: *std.Io.Writer,
bytes: []const u8,
