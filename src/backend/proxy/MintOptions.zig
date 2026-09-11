const MintOptions = @This();
const source_namespace = @import("tls.zig");
const std = @import("std");
const ca = @import("ca.zig");
io: source_namespace.Io,
gpa: std.mem.Allocator,
authority: *const ca.Authority,
host: []const u8,
