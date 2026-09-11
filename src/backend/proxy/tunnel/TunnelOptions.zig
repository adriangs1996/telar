const Dependencies = @import("Dependencies.zig");
const std = @import("std");
const Options = @This();

dependencies: Dependencies,
child: std.Io.net.Stream,
