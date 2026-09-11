/// Accepts tunnels until cancelled. One task per connection.
const ServeContext = @This();
const source_namespace = @import("proxy.zig");
const ca = @import("ca.zig");
const std = @import("std");
const event = @import("event.zig");
io: source_namespace.Io,
port: u16,
authority: ca.Authority,
allocator: std.mem.Allocator,
queue: *event.Queue,
