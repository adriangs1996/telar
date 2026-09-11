const std = @import("std");
const AuthorityType = @import("Authority.zig");
const Roots = @import("Roots.zig");
/// Handshakes both ends. `host` is the CONNECT target, used both to mint the
/// certificate the child will check and to verify the real server. `cause`
/// receives the underlying failure, which the returned `Error` only categorises.
const InterceptResources = @This();

io: std.Io,
allocator: std.mem.Allocator,
authority: AuthorityType,
roots: Roots,
