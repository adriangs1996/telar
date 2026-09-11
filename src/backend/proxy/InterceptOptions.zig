const InterceptOptions = @This();
const source_namespace = @import("tls.zig");
const std = @import("std");
const ca = @import("ca.zig");
const Roots = @import("Roots.zig");
io: source_namespace.Io,
gpa: std.mem.Allocator,
authority: *const ca.Authority,
roots: *const Roots,
host: []const u8,
child: source_namespace.net.Stream,
origin: source_namespace.net.Stream,
