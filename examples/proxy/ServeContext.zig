const std = @import("std");
const AuthorityType = @import("Authority.zig");
const event = @import("event.zig");
/// Accepts tunnels until cancelled. One task per connection.
const ServeContext = @This();

io: std.Io,
port: u16,
authority: AuthorityType,
allocator: std.mem.Allocator,
queue: *event.Queue,
