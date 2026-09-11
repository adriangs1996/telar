const std = @import("std");
const AuthorityType = @import("Authority.zig");
const Roots = @import("Roots.zig");
const InterceptOptions = @This();

io: std.Io,
gpa: std.mem.Allocator,
authority: *const AuthorityType,
roots: *const Roots,
host: []const u8,
child: std.Io.net.Stream,
origin: std.Io.net.Stream,
