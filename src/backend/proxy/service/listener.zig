const Listener = @This();
const source_namespace = @import("listener_support.zig");
server: source_namespace.net.Server,
bound_port: u16,

/// Binds the first available loopback port in Telar's bounded proxy range.
/// Ports already owned by another process are skipped; exhaustion is
/// reported as `error.ProxyPortUnavailable`.
///
/// ```zig
/// var listener = try Listener.bind(io);
/// defer listener.deinit(io);
/// ```
pub fn bind(io: source_namespace.Io) !Listener {
    var candidate_port = source_namespace.first_port;
    while (candidate_port < source_namespace.first_port + source_namespace.port_attempts) : (candidate_port += 1) {
        const address = source_namespace.net.IpAddress.parse("127.0.0.1", candidate_port) catch unreachable;
        const server = address.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => continue,
            else => |other| return other,
        };

        return .{ .server = server, .bound_port = candidate_port };
    }

    return error.ProxyPortUnavailable;
}

/// Closes the owned listening socket.
///
/// ```zig
/// listener.deinit(io);
/// ```
pub fn deinit(listener: *Listener, io: source_namespace.Io) void {
    listener.server.deinit(io);
}

/// Waits for one incoming loopback connection.
///
/// ```zig
/// const stream = try listener.accept(io);
/// ```
pub fn accept(listener: *Listener, io: source_namespace.Io) !source_namespace.net.Stream {
    return listener.server.accept(io);
}

/// Returns the port selected during `bind`.
///
/// ```zig
/// const port = listener.port();
/// ```
pub fn port(listener: *const Listener) u16 {
    return listener.bound_port;
}
