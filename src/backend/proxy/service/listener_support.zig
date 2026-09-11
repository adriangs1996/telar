//! Bounded loopback listener for the local proxy capability.

const std = @import("std");

pub const Io = std.Io;
pub const net = Io.net;

pub const first_port: u16 = 45100;
pub const port_attempts: u16 = 128;

pub const Listener = @import("Listener.zig");

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
