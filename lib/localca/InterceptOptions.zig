const std = @import("std");
const Authority = @import("Authority.zig");
const Roots = @import("Roots.zig");
const InterceptOptions = @This();

io: std.Io,
gpa: std.mem.Allocator,
authority: *const Authority,
roots: *const Roots,
host: []const u8,
child: std.Io.net.Stream,
origin: std.Io.net.Stream,
