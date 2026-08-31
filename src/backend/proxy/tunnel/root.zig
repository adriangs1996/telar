//! One authenticated CONNECT tunnel from request head through protocol relay.

const std = @import("std");
const core = @import("telar-core");
const connect_authentication = @import("../connect_authentication.zig");
const credential_registry = @import("../credential_registry.zig");
const http = @import("../http/root.zig");
const identity = @import("../identity.zig");
const metrics = @import("../metrics.zig");
const middleware = @import("../middleware.zig");
const provider = @import("../provider/root.zig");
const exchange_mod = @import("exchange.zig");
const h2_adapter = @import("h2.zig");
const http1_adapter = @import("http1.zig");
const tls_adapter = @import("tls.zig");

const Io = std.Io;
const net = Io.net;
const diagnostics = core.diagnostics;

pub const Dependencies = struct {
    tls: tls_adapter.Resources,
    credentials: *credential_registry.Registry,
    pipeline: *const middleware.Pipeline,
    transforms: *const middleware.TransformPipeline,
    has_custom_transformers: bool,
    connection_ids: *std.atomic.Value(u64),
};

pub const Options = struct {
    dependencies: Dependencies,
    child: net.Stream,
};

pub const Tunnel = struct {
    dependencies: Dependencies,
    child: net.Stream,

    /// Creates the per-connection owner without starting network work.
    ///
    /// ```zig
    /// var tunnel = Tunnel.init(.{ .dependencies = dependencies, .child = child });
    /// ```
    pub fn init(options: Options) Tunnel {
        return .{
            .dependencies = options.dependencies,
            .child = options.child,
        };
    }

    /// Authenticates one CONNECT request, opens its origin, establishes TLS,
    /// and delegates the negotiated protocol until the connection ends.
    /// The tunnel always closes its accepted child stream before returning.
    ///
    /// ```zig
    /// try tunnel.run();
    /// ```
    pub fn run(tunnel: *Tunnel) Io.Cancelable!void {
        const path = diagnostics.enter(.observation);
        defer path.restore();

        const dependencies = tunnel.dependencies;
        const io = dependencies.tls.io;
        defer tunnel.child.close(io);

        var head: [http.max_head_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &head);
        const head_len = readConnectHead(io, tunnel.child, &head) orelse return;
        var authenticated = switch (Authenticate.execute(tunnel, head[0..head_len])) {
            .authenticated => |value| value,
            .rejected => |rejection| {
                if (rejection.metric) |metric| {
                    recordAuthenticationRejection(dependencies.tls.telemetry, metric);
                }

                reply(io, tunnel.child, rejection.response);
                return;
            },
        };
        defer std.crypto.secureZero(u8, &authenticated.credential.token);

        const target = authenticated.target;
        var exchange: exchange_mod.Exchange = .{
            .io = io,
            .pipeline = dependencies.pipeline,
            .telemetry = dependencies.tls.telemetry,
            .credential = authenticated.credential,
            .provider = provider.identify(target.host.bytes),
            .connection_id = dependencies.connection_ids.fetchAdd(1, .monotonic),
            .protocol = .http11,
        };
        defer std.crypto.secureZero(u8, &exchange.credential.token);

        const upstream = connectUpstream(target.host, io, target.port) catch {
            dependencies.tls.telemetry.record(.upstream_connect_failure);
            exchange.publish(.request_failed, 0);
            reply(io, tunnel.child, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
            return;
        };
        defer upstream.close(io);
        reply(io, tunnel.child, "HTTP/1.1 200 Connection Established\r\n\r\n");

        var tls_establisher: tls_adapter.Establisher = .{
            .resources = dependencies.tls,
            .exchange = &exchange,
        };
        const route = tls_establisher.establish(.{
            .host = target.host.bytes,
            .child = tunnel.child,
            .origin = upstream,
        }) orelse return;

        var negotiated_h2 = false;
        const session = switch (route) {
            .passthrough => {
                relayPassthrough(io, tunnel.child, upstream);
                return;
            },
            .http11 => |established| established,
            .h2 => |established| block: {
                negotiated_h2 = true;
                break :block established;
            },
        };
        defer session.deinit();

        exchange.protocol = if (negotiated_h2) .h2 else .http11;
        if (negotiated_h2) {
            var connection = h2_adapter.Connection.init(.{
                .io = io,
                .gpa = dependencies.tls.gpa,
                .transforms = dependencies.transforms,
                .has_custom_transformers = dependencies.has_custom_transformers,
                .session = session,
                .exchange = &exchange,
            });

            connection.run();
            return;
        }

        var connection = http1_adapter.Connection.init(.{
            .io = io,
            .transforms = dependencies.transforms,
            .session = session,
            .exchange = &exchange,
        });
        connection.run();
    }
};

const credential_port: connect_authentication.CredentialPort(Tunnel) = .{
    .contains = containsCredential,
};

const Authenticate = connect_authentication.Command(Tunnel, credential_port);

fn containsCredential(tunnel: *Tunnel, credential: *const identity.Credential) bool {
    return tunnel.dependencies.credentials.contains(tunnel.dependencies.tls.io, credential);
}

fn recordAuthenticationRejection(telemetry: *metrics.Counters, rejection: connect_authentication.RejectionMetric) void {
    telemetry.record(.rejected_connection);

    switch (rejection) {
        .invalid_authorization => telemetry.record(.invalid_authorization_rejection),
        .unknown_credential => telemetry.record(.unknown_credential_rejection),
    }
}

fn relayPassthrough(io: Io, child: net.Stream, origin: net.Stream) void {
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

fn readConnectHead(io: Io, stream: net.Stream, buffer: []u8) ?usize {
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

fn reply(io: Io, stream: net.Stream, bytes: []const u8) void {
    var buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    writer.interface.writeAll(bytes) catch return;
    writer.interface.flush() catch {};
}

// Resolve asynchronously but connect sequentially. This avoids a Zig 0.16
// Darwin race where concurrent connect attempts can report EISCONN.
fn connectUpstream(host: net.HostName, io: Io, port: u16) !net.Stream {
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
