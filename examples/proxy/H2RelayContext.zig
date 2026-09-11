const std = @import("std");
const SessionType = @import("Session.zig");
const UpstreamType = @import("Upstream.zig");
const event = @import("event.zig");
/// Runs both directions of an h2 connection and records one exchange for the
/// whole thing. Per-stream splitting is the next step; this is the connection.
const H2RelayContext = @This();

io: std.Io,
session: *SessionType,
allocator: std.mem.Allocator,
id: u64,
opened: UpstreamType,
port: u16,
queue: *event.Queue,
