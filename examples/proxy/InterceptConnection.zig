const std = @import("std");
const InterceptConnection = @This();

host: []const u8,
child: std.Io.net.Stream,
origin: std.Io.net.Stream,
