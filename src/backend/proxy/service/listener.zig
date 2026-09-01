//! Bounded loopback listener for the local proxy capability.

const std = @import("std");

const Io = std.Io;
const net = Io.net;

const first_port: u16 = 45100;
const port_attempts: u16 = 128;

pub const Listener = struct {
    server: net.Server,
    bound_port: u16,

    /// Binds the first available loopback port in Telar's bounded proxy range.
    /// Ports already owned by another process are skipped; exhaustion is
    /// reported as `error.ProxyPortUnavailable`.
    ///
    /// ```zig
    /// var listener = try Listener.bind(io);
    /// defer listener.deinit(io);
    /// ```
    pub fn bind(io: Io) !Listener {
        var candidate_port = first_port;
        while (candidate_port < first_port + port_attempts) : (candidate_port += 1) {
            const address = net.IpAddress.parse("127.0.0.1", candidate_port) catch unreachable;
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
    pub fn deinit(listener: *Listener, io: Io) void {
        listener.server.deinit(io);
    }

    /// Waits for one incoming loopback connection.
    ///
    /// ```zig
    /// const stream = try listener.accept(io);
    /// ```
    pub fn accept(listener: *Listener, io: Io) !net.Stream {
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
};

test "listeners skip ports already owned by another proxy listener" {
    const io = std.testing.io;
    var first = try Listener.bind(io);
    defer first.deinit(io);
    var second = try Listener.bind(io);
    defer second.deinit(io);

    try std.testing.expect(first.port() != second.port());
    try std.testing.expect(first.port() >= first_port);
    try std.testing.expect(first.port() < first_port + port_attempts);
    try std.testing.expect(second.port() >= first_port);
    try std.testing.expect(second.port() < first_port + port_attempts);
}
