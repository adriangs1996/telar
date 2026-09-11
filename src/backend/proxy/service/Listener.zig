const std = @import("std");
const listener_support = @import("listener_support.zig");
const Listener = @This();

server: std.Io.net.Server,
bound_port: u16,

/// Binds the first available loopback port in Telar's bounded proxy range.
/// Ports already owned by another process are skipped; exhaustion is
/// reported as `error.ProxyPortUnavailable`.
///
/// ```zig
/// var listener = try Listener.bind(io);
/// defer listener.deinit(io);
/// ```
pub fn bind(io: std.Io) !Listener {
    var candidate_port = listener_support.first_port;
    while (candidate_port < listener_support.first_port + listener_support.port_attempts) : (candidate_port += 1) {
        const address = std.Io.net.IpAddress.parse("127.0.0.1", candidate_port) catch unreachable;
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
pub fn deinit(listener: *Listener, io: std.Io) void {
    listener.server.deinit(io);
}

/// Waits for one incoming loopback connection.
///
/// ```zig
/// const stream = try listener.accept(io);
/// ```
pub fn accept(listener: *Listener, io: std.Io) !std.Io.net.Stream {
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
