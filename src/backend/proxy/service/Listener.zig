const std = @import("std");
const listener_support = @import("listener_support.zig");
const Listener = @This();

server: std.Io.net.Server,
bound_port: u16,

/// Binds the preferred loopback port when one is given and free, else the
/// first available port in Telar's bounded proxy range. Ports already owned
/// by another process are skipped; exhaustion is reported as
/// `error.ProxyPortUnavailable`.
///
/// ```zig
/// var listener = try Listener.bind(io, preferred_port);
/// defer listener.deinit(io);
/// ```
pub fn bind(io: std.Io, preferred: ?u16) !Listener {
    if (preferred) |port_value| {
        if (try bindPort(io, port_value)) |bound| {
            return bound;
        }
    }

    var candidate_port = listener_support.first_port;
    while (candidate_port < listener_support.first_port + listener_support.port_attempts) : (candidate_port += 1) {
        if (try bindPort(io, candidate_port)) |bound| {
            return bound;
        }
    }

    return error.ProxyPortUnavailable;
}

fn bindPort(io: std.Io, port_value: u16) !?Listener {
    const address = std.Io.net.IpAddress.parse("127.0.0.1", port_value) catch unreachable;
    const server = address.listen(io, .{}) catch |err| switch (err) {
        error.AddressInUse => return null,
        else => |other| return other,
    };

    return .{ .server = server, .bound_port = port_value };
}

/// Closes the owned listening socket.
///
/// ```zig
/// listener.deinit(io);
/// ```
pub fn deinit(self: *Listener, io: std.Io) void {
    self.server.deinit(io);
}

/// Waits for one incoming loopback connection.
///
/// ```zig
/// const stream = try listener.accept(io);
/// ```
pub fn accept(self: *Listener, io: std.Io) !std.Io.net.Stream {
    return self.server.accept(io);
}

/// Returns the port selected during `bind`.
///
/// ```zig
/// const port = listener.port();
/// ```
pub fn port(self: *const Listener) u16 {
    return self.bound_port;
}
