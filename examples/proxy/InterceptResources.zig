/// Handshakes both ends. `host` is the CONNECT target, used both to mint the
/// certificate the child will check and to verify the real server. `cause`
/// receives the underlying failure, which the returned `Error` only categorises.
const InterceptResources = @This();
const source_namespace = @import("tls.zig");
const std = @import("std");
const ca = @import("ca.zig");
const Roots = @import("Roots.zig");
io: source_namespace.Io,
allocator: std.mem.Allocator,
authority: ca.Authority,
roots: Roots,
