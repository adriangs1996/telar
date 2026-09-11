//! One authenticated CONNECT tunnel from request head through protocol relay.

const std = @import("std");
const core = @import("telar-core");
const connect_authentication = @import("../connect_authentication.zig");
const capture = @import("../capture/root.zig");
const credential_registry = @import("../credential_registry.zig");
const http = @import("../http/root.zig");
const identity = @import("../identity.zig");
const metrics = @import("../metrics.zig");
const middleware = @import("../middleware.zig");
const provider = @import("../provider/root.zig");
const exchange_mod = @import("exchange_support.zig");
const h2_adapter = @import("h2.zig");
const http1_adapter = @import("http1.zig");
const tls_adapter = @import("tls.zig");

pub const Io = std.Io;
pub const net = Io.net;
pub const diagnostics = core.diagnostics;

pub const Dependencies = @import("Dependencies.zig");

pub const Options = @import("TunnelOptions.zig");

pub const Tunnel = @import("Tunnel.zig");

const credential_port: connect_authentication.CredentialPort(Tunnel) = .{
    .contains = containsCredential,
};

pub const Authenticate = connect_authentication.Command(Tunnel, credential_port);

fn containsCredential(tunnel: *Tunnel, credential: *const identity.Credential) bool {
    return tunnel.dependencies.credentials.contains(tunnel.dependencies.tls.io, credential);
}

pub fn recordAuthenticationRejection(telemetry: *metrics.Counters, rejection: connect_authentication.RejectionMetric) void {
    telemetry.record(.rejected_connection);

    switch (rejection) {
        .invalid_authorization => telemetry.record(.invalid_authorization_rejection),
        .unknown_credential => telemetry.record(.unknown_credential_rejection),
    }
}

pub fn relayPassthrough(io: Io, child: net.Stream, origin: net.Stream) void {
    var outbound = io.concurrent(pumpPassthrough, .{ io, child, origin }) catch return;
    pumpPassthrough(io, origin, child);
    outbound.await(io);
}

fn pumpPassthrough(io: Io, source: net.Stream, destination: net.Stream) void {
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
    }

    destination.shutdown(io, .send) catch {};
}

pub fn readConnectHead(io: Io, stream: net.Stream, buffer: []u8) ?usize {
    var read_buffer: [8 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &read_buffer);
    var reader = stream.reader(io, &read_buffer);
    var len: usize = 0;

    while (len < buffer.len) {
        const byte = reader.interface.takeByte() catch return null;
        buffer[len] = byte;
        len += 1;

        if (len >= 4 and std.mem.eql(u8, buffer[len - 4 .. len], "\r\n\r\n")) {
            return len;
        }
    }

    return null;
}

pub fn reply(io: Io, stream: net.Stream, bytes: []const u8) void {
    var buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    writer.interface.writeAll(bytes) catch return;
    writer.interface.flush() catch {};
}

// Resolve asynchronously but connect sequentially. This avoids a Zig 0.16
// Darwin race where concurrent connect attempts can report EISCONN.
pub fn connectUpstream(host: net.HostName, io: Io, port: u16) !net.Stream {
    var lookup_storage: [32]net.HostName.LookupResult = undefined;
    var resolved: Io.Queue(net.HostName.LookupResult) = .init(&lookup_storage);
    var lookup = io.async(net.HostName.lookup, .{ host, io, &resolved, .{ .port = port } });
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
    var invalid: metrics.Counters = .{};
    recordAuthenticationRejection(&invalid, .invalid_authorization);
    const invalid_snapshot = snapshot(&invalid);

    try std.testing.expectEqual(@as(u64, 1), invalid_snapshot.rejected_connections);
    try std.testing.expectEqual(@as(u64, 1), invalid_snapshot.invalid_authorization_rejections);
    try std.testing.expectEqual(@as(u64, 0), invalid_snapshot.unknown_credential_rejections);

    var unknown: metrics.Counters = .{};
    recordAuthenticationRejection(&unknown, .unknown_credential);
    const unknown_snapshot = snapshot(&unknown);

    try std.testing.expectEqual(@as(u64, 1), unknown_snapshot.rejected_connections);
    try std.testing.expectEqual(@as(u64, 0), unknown_snapshot.invalid_authorization_rejections);
    try std.testing.expectEqual(@as(u64, 1), unknown_snapshot.unknown_credential_rejections);
}

fn snapshot(telemetry: *const metrics.Counters) metrics.Snapshot {
    return telemetry.snapshot(.{
        .connections = .{ .active = 0, .limit_drops = 0 },
        .observations = .{ .queued = 0, .high_water = 0, .dropped = 0 },
    });
}
