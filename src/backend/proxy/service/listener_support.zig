//! Bounded loopback listener for the local proxy capability.

const std = @import("std");
const Listener = @import("Listener.zig");

pub const first_port: u16 = 45100;
pub const port_attempts: u16 = 128;

test "listeners prefer the remembered port and skip ports another listener owns" {
    const io = std.testing.io;
    var first = try Listener.bind(io, null);
    defer first.deinit(io);
    var second = try Listener.bind(io, first.port());
    defer second.deinit(io);
    var preferred = try Listener.bind(io, first_port + port_attempts - 1);
    defer preferred.deinit(io);

    try std.testing.expect(first.port() != second.port());
    try std.testing.expect(first.port() >= first_port);
    try std.testing.expect(first.port() < first_port + port_attempts);
    try std.testing.expect(second.port() >= first_port);
    try std.testing.expect(second.port() < first_port + port_attempts);
    try std.testing.expectEqual(first_port + port_attempts - 1, preferred.port());
}
