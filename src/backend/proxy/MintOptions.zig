const std = @import("std");
const AuthorityType = @import("Authority.zig");
const MintOptions = @This();

io: std.Io,
gpa: std.mem.Allocator,
authority: *const AuthorityType,
host: []const u8,
