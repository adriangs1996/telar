//! One authenticated CONNECT tunnel from request head through protocol relay.

const Counters = @import("../Counters.zig");
const Exchange = @import("Exchange.zig");
const connect_authentication = @import("../connect_authentication.zig");
const std = @import("std");
const Snapshot = @import("../Snapshot.zig");

pub fn recordAuthenticationRejection(telemetry: *Counters, rejection: connect_authentication.RejectionMetric) void {
    telemetry.record(.rejected_connection);

    switch (rejection) {
        .invalid_authorization => telemetry.record(.invalid_authorization_rejection),
        .unknown_credential => telemetry.record(.unknown_credential_rejection),
    }
}

/// Relays opaque bytes both ways until either side closes; every copy
/// marks the connection active.
///
/// ```zig
/// tunnel_namespace.relayPassthrough(child, origin, &exchange);
/// ```
pub fn relayPassthrough(child: std.Io.net.Stream, origin: std.Io.net.Stream, exchange: *Exchange) void {
    const io = exchange.io;
    var outbound = io.concurrent(pumpPassthrough, .{ child, origin, exchange }) catch return;
    pumpPassthrough(origin, child, exchange);
    outbound.await(io);
}

fn pumpPassthrough(source: std.Io.net.Stream, destination: std.Io.net.Stream, exchange: *Exchange) void {
    const io = exchange.io;
    var read_buffer: [16 * 1024]u8 = undefined;
    var write_buffer: [16 * 1024]u8 = undefined;
    var reader = source.reader(io, &read_buffer);
    var writer = destination.writer(io, &write_buffer);

    while (true) {
        const copied = reader.interface.stream(&writer.interface, .unlimited) catch break;
        writer.interface.flush() catch break;

        if (copied == 0) {
            break;
        }

        exchange.touch();
    }

    destination.shutdown(io, .send) catch {};
}

/// Reads one CONNECT head into `buffer`: its length, the end of the
/// stream, or a head past the buffer, which the caller answers with 431.
///
/// ```zig
/// switch (tunnel_namespace.readConnectHead(io, stream, &head)) { ... }
/// ```
pub fn readConnectHead(io: std.Io, stream: std.Io.net.Stream, buffer: []u8) ConnectHead {
    var read_buffer: [connect_read_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &read_buffer);
    var reader = stream.reader(io, &read_buffer);
    var len: usize = 0;

    while (len < buffer.len) {
        const byte = reader.interface.takeByte() catch return .ended;
        buffer[len] = byte;
        len += 1;

        if (len >= 4 and std.mem.eql(u8, buffer[len - 4 .. len], "\r\n\r\n")) {
            return .{ .complete = len };
        }
    }

    return .too_large;
}

/// Bytes the CONNECT head reader buffers per read.
const connect_read_bytes = 8 * 1024;

/// What reading a CONNECT head found.
const ConnectHead = union(enum) {
    complete: usize,
    ended,
    too_large,
};

pub fn reply(io: std.Io, stream: std.Io.net.Stream, bytes: []const u8) void {
    var buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    writer.interface.writeAll(bytes) catch return;
    writer.interface.flush() catch {};
}

// Resolve asynchronously but connect sequentially. This avoids a Zig 0.16
// Darwin race where concurrent connect attempts can report EISCONN.
pub fn connectUpstream(host: std.Io.net.HostName, io: std.Io, port: u16) !std.Io.net.Stream {
    var lookup_storage: [32]std.Io.net.HostName.LookupResult = undefined;
    var resolved: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_storage);
    var lookup = io.async(std.Io.net.HostName.lookup, .{ host, io, &resolved, .{ .port = port } });
    defer lookup.cancel(io) catch {};
    var last_error: ?anyerror = null;

    while (resolved.getOne(io)) |result| switch (result) {
        .canonical_name => continue,
        .address => |address| {
            if (address.connect(io, .{ .mode = .stream })) |stream| {
                return stream;
            } else |err| {
                last_error = err;
            }
        },
    } else |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Closed => {
            try lookup.await(io);
            return last_error orelse error.UnknownHostName;
        },
    }
}

test "authentication rejection records total and exact reason" {
    var invalid: Counters = .{};
    recordAuthenticationRejection(&invalid, .invalid_authorization);
    const invalid_snapshot = snapshot(&invalid);

    try std.testing.expectEqual(@as(u64, 1), invalid_snapshot.rejected_connections);
    try std.testing.expectEqual(@as(u64, 1), invalid_snapshot.invalid_authorization_rejections);
    try std.testing.expectEqual(@as(u64, 0), invalid_snapshot.unknown_credential_rejections);

    var unknown: Counters = .{};
    recordAuthenticationRejection(&unknown, .unknown_credential);
    const unknown_snapshot = snapshot(&unknown);

    try std.testing.expectEqual(@as(u64, 1), unknown_snapshot.rejected_connections);
    try std.testing.expectEqual(@as(u64, 0), unknown_snapshot.invalid_authorization_rejections);
    try std.testing.expectEqual(@as(u64, 1), unknown_snapshot.unknown_credential_rejections);
}

fn snapshot(telemetry: *const Counters) Snapshot {
    return telemetry.snapshot(.{
        .connections = .{ .active = 0, .limit_drops = 0 },
    });
}
