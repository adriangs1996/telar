/// Runs both directions of an h2 connection and records one exchange for the
/// whole thing. Per-stream splitting is the next step; this is the connection.
const H2RelayContext = @This();
const source_namespace = @import("proxy.zig");
const tls = @import("tls.zig");
const std = @import("std");
const event = @import("event.zig");
io: source_namespace.Io,
session: *tls.Session,
allocator: std.mem.Allocator,
id: u64,
opened: event.Upstream,
port: u16,
queue: *event.Queue,
