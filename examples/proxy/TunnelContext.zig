const TunnelContext = @This();
const source_namespace = @import("proxy.zig");
const ca = @import("ca.zig");
const tls = @import("tls.zig");
const std = @import("std");
const event = @import("event.zig");
io: source_namespace.Io,
stream: source_namespace.net.Stream,
authority: ca.Authority,
roots: tls.Roots,
allocator: std.mem.Allocator,
queue: *event.Queue,
next_id: *std.atomic.Value(u64),
