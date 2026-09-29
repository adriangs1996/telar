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

test "a restarted listener gets back a port its closed connections leave in TIME_WAIT" {
    const io = std.testing.io;
    var first = try Listener.bind(io, null);
    const port = first.port();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const client = try address.connect(io, .{ .mode = .stream });
    const accepted = try first.accept(io);

    // The side that closes first keeps TIME_WAIT: here the listener's port.
    accepted.close(io);
    var byte: [1]u8 = undefined;
    var reader_buffer: [16]u8 = undefined;
    var reader = client.reader(io, &reader_buffer);
    try std.testing.expectError(error.EndOfStream, reader.interface.readSliceAll(&byte));
    client.close(io);
    first.deinit(io);

    var restarted = try Listener.bind(io, port);
    defer restarted.deinit(io);
    try std.testing.expectEqual(port, restarted.port());
}

test "a listener never shadows another process listening on every address" {
    const io = std.testing.io;
    var probe = try Listener.bind(io, null);
    const port = probe.port();
    probe.deinit(io);

    const wildcard = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    var foreign = try wildcard.listen(io, .{ .reuse_address = true });
    defer foreign.deinit(io);

    var listener = try Listener.bind(io, port);
    defer listener.deinit(io);
    try std.testing.expect(listener.port() != port);
}
