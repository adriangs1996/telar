//! Bounded loopback listener for the local proxy capability.

const std = @import("std");
const Listener = @import("Listener.zig");

pub const first_port: u16 = 45100;
pub const port_attempts: u16 = 128;
/// A set of proxy ports, each one its offset from `first_port`.
pub const PortSet = std.StaticBitSet(port_attempts);

test "listeners prefer the remembered port and skip ports another listener owns" {
    const io = std.testing.io;
    const none: PortSet = .initEmpty();
    var first = try Listener.bind(io, null, &none);
    defer first.deinit(io);
    var second = try Listener.bind(io, first.port(), &none);
    defer second.deinit(io);
    var preferred = try Listener.bind(io, first_port + port_attempts - 1, &none);
    defer preferred.deinit(io);

    try std.testing.expect(first.port() != second.port());
    try std.testing.expect(first.port() >= first_port);
    try std.testing.expect(first.port() < first_port + port_attempts);
    try std.testing.expect(second.port() >= first_port);
    try std.testing.expect(second.port() < first_port + port_attempts);
    try std.testing.expectEqual(first_port + port_attempts - 1, preferred.port());
}

test "listeners leave the ports other runtimes remember until nothing else is free" {
    const io = std.testing.io;
    const none: PortSet = .initEmpty();
    var probe = try Listener.bind(io, null, &none);
    const lowest_free = probe.port();
    probe.deinit(io);

    var reserved: PortSet = .initEmpty();
    reserved.set(lowest_free - first_port);
    var avoiding = try Listener.bind(io, null, &reserved);
    defer avoiding.deinit(io);
    try std.testing.expect(avoiding.port() != lowest_free);

    var everything: PortSet = .initFull();
    everything.unset(avoiding.port() - first_port);
    var fallback = try Listener.bind(io, null, &everything);
    defer fallback.deinit(io);
    try std.testing.expect(fallback.port() >= first_port);
    try std.testing.expect(fallback.port() < first_port + port_attempts);
}

test "a restarted listener gets back a port its closed connections leave in TIME_WAIT" {
    const io = std.testing.io;
    const none: PortSet = .initEmpty();
    var first = try Listener.bind(io, null, &none);
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

    var restarted = try Listener.bind(io, port, &none);
    defer restarted.deinit(io);
    try std.testing.expectEqual(port, restarted.port());
}

test "a listener never shadows another process listening on every address" {
    const io = std.testing.io;
    const none: PortSet = .initEmpty();
    var probe = try Listener.bind(io, null, &none);
    const port = probe.port();
    probe.deinit(io);

    const wildcard = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    var foreign = try wildcard.listen(io, .{ .reuse_address = true });
    defer foreign.deinit(io);

    var listener = try Listener.bind(io, port, &none);
    defer listener.deinit(io);
    try std.testing.expect(listener.port() != port);
}
