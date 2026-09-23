const std = @import("std");
const Authority = @import("Authority.zig");
const MintOptions = @This();

io: std.Io,
gpa: std.mem.Allocator,
authority: *const Authority,
host: []const u8,
