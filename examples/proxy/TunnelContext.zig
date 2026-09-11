const std = @import("std");
const AuthorityType = @import("Authority.zig");
const RootsType = @import("Roots.zig");
const event = @import("event.zig");
const TunnelContext = @This();

io: std.Io,
stream: std.Io.net.Stream,
authority: AuthorityType,
roots: RootsType,
allocator: std.mem.Allocator,
queue: *event.Queue,
next_id: *std.atomic.Value(u64),
