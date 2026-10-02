//! Contract and integration tests for the proxy service.

const std = @import("std");
const Resolutions = @import("../Resolutions.zig");
const gated_resolver = @import("../gated_resolver.zig");
const service_support = @import("service_support.zig");
const Service = @import("Service.zig");
const Paths = @import("Paths.zig");
const TunnelJoin = @import("TunnelJoin.zig").TunnelJoin;
const TunnelTestGate = @import("TunnelTestGate.zig");
const identity = @import("../identity.zig");
const Connections = @import("../Connections.zig");

const basic_raw_capacity = 128;
const basic_encoded_capacity = std.base64.standard.Encoder.calcSize(basic_raw_capacity);

fn encodeBasic(secret: *const identity.Secret, raw_buffer: *[basic_raw_capacity]u8, encoded_buffer: *[basic_encoded_capacity]u8) ![]const u8 {
    const raw = try std.fmt.bufPrint(raw_buffer, "telar:{x}", .{secret.*});
    const encoded_len = std.base64.standard.Encoder.calcSize(raw.len);

    return std.base64.standard.Encoder.encode(encoded_buffer[0..encoded_len], raw);
}

test "running service leaves exchange capture inert when disabled" {
    var fixture: TestServiceFixture = .{};
    try fixture.init(std.testing.io, std.testing.allocator, &.{});
    defer fixture.deinit();
    const service = fixture.service.?;
    try service.start();

    try std.testing.expectEqual(TunnelJoin.joined, service.stop());

    const snapshot = service.metrics();
    try std.testing.expectEqual(@as(u64, 0), snapshot.capture_started);
    try std.testing.expectEqual(@as(u64, 0), snapshot.capture_skipped);
    try std.testing.expectEqual(@as(u64, 0), snapshot.queued_captures);
}

test "the proxy secret and port persist across service restarts" {
    const io = std.testing.io;
    var fixture: TestServiceFixture = .{};
    try fixture.init(io, std.testing.allocator, &.{});
    defer fixture.deinit();
    const first_secret = fixture.service.?.secret;
    const first_port = fixture.service.?.clientConfiguration().port;
    var url_buffer: [256]u8 = undefined;
    const url = try fixture.service.?.proxyUrl(&url_buffer);
    try std.testing.expect(std.mem.startsWith(u8, url, "http://telar:"));
    try std.testing.expect(std.mem.indexOf(u8, url, "@127.0.0.1:") != null);

    fixture.service.?.destroy();
    fixture.service = try Service.create(io, std.testing.allocator, fixture.paths(&.{}));

    try std.testing.expect(identity.sameSecret(&first_secret, &fixture.service.?.secret));
    try std.testing.expectEqual(first_port, fixture.service.?.clientConfiguration().port);
}

fn echoOpaquePayload(io: std.Io, listener: *std.Io.net.Server, expected: []const u8) !void {
    const stream = try listener.accept(io);
    defer stream.close(io);
    var read_buffer: [256]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var payload: [256]u8 = undefined;
    for (payload[0..expected.len]) |*byte| byte.* = try reader.interface.takeByte();
    try std.testing.expectEqualStrings(expected, payload[0..expected.len]);
    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(payload[0..expected.len]);
    try writer.interface.flush();
}

fn rejectTlsHandshake(io: std.Io, listener: *std.Io.net.Server) !void {
    const stream = try listener.accept(io);
    defer stream.close(io);

    var write_buffer: [32]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(&.{ 0x16, 0x03, 0x03, 0xff, 0xff });
    try writer.interface.flush();
}

fn acceptAndClose(io: std.Io, listener: *std.Io.net.Server) !void {
    const stream = try listener.accept(io);
    stream.close(io);
}

fn listenTestOrigin(io: std.Io) !TestOrigin {
    var port: u16 = 49_152;
    while (port < 49_280) : (port += 1) {
        const address = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
        const listener = address.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => continue,
            else => |other| return other,
        };
        return .{ .listener = listener, .port = port };
    }
    return error.TestOriginPortUnavailable;
}

test "non-whitelisted CONNECT relays bytes untouched" {
    const io = std.testing.io;
    const payload = "not-a-tls-client-hello";
    var origin = try listenTestOrigin(io);
    defer origin.listener.deinit(io);
    var origin_worker = try io.concurrent(echoOpaquePayload, .{ io, &origin.listener, payload });
    defer origin_worker.cancel(io) catch {};

    var fixture: TestServiceFixture = .{};
    try fixture.init(io, std.testing.allocator, &.{"api.openai.com"});
    defer fixture.deinit();
    const service = fixture.service.?;
    try service.start();
    defer _ = service.stop();

    const proxy_address = try std.Io.net.IpAddress.parse("127.0.0.1", service.clientConfiguration().port);
    const client = try proxy_address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var write_buffer: [512]u8 = undefined;
    var writer = client.writer(io, &write_buffer);
    var raw_buffer: [basic_raw_capacity]u8 = undefined;
    defer std.crypto.secureZero(u8, &raw_buffer);
    var encoded_buffer: [basic_encoded_capacity]u8 = undefined;
    defer std.crypto.secureZero(u8, &encoded_buffer);
    const basic = try encodeBasic(&service.secret, &raw_buffer, &encoded_buffer);
    var request_buffer: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_buffer,
        "CONNECT localhost:{d} HTTP/1.1\r\nProxy-Authorization: Basic {s}\r\n\r\n",
        .{ origin.port, basic },
    );
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    var read_buffer: [512]u8 = undefined;
    var reader = client.reader(io, &read_buffer);
    var response: ["HTTP/1.1 200 Connection Established\r\n\r\n".len]u8 = undefined;
    try reader.interface.readSliceAll(&response);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 Connection Established\r\n\r\n",
        &response,
    );

    try writer.interface.writeAll(payload);
    try writer.interface.flush();
    var echoed: [payload.len]u8 = undefined;
    for (&echoed) |*byte| byte.* = try reader.interface.takeByte();
    try std.testing.expectEqualStrings(payload, &echoed);
    client.shutdown(io, .send) catch {};
    try origin_worker.await(io);
    try std.testing.expectEqual(
        @as(u64, 1),
        service.metrics().passthrough_connections,
    );
}

test "intercepted CONNECT counts an upstream TLS failure" {
    const io = std.testing.io;
    var origin = try listenTestOrigin(io);
    defer origin.listener.deinit(io);
    var origin_worker = try io.concurrent(rejectTlsHandshake, .{ io, &origin.listener });
    defer origin_worker.cancel(io) catch {};

    var fixture: TestServiceFixture = .{};
    try fixture.init(io, std.testing.allocator, &.{"localhost"});
    defer fixture.deinit();
    const service = fixture.service.?;
    try service.start();
    defer _ = service.stop();

    const proxy_address = try std.Io.net.IpAddress.parse("127.0.0.1", service.clientConfiguration().port);
    const client = try proxy_address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var write_buffer: [512]u8 = undefined;
    var writer = client.writer(io, &write_buffer);
    var raw_buffer: [basic_raw_capacity]u8 = undefined;
    defer std.crypto.secureZero(u8, &raw_buffer);
    var encoded_buffer: [basic_encoded_capacity]u8 = undefined;
    defer std.crypto.secureZero(u8, &encoded_buffer);
    const basic = try encodeBasic(&service.secret, &raw_buffer, &encoded_buffer);
    var request_buffer: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_buffer,
        "CONNECT localhost:{d} HTTP/1.1\r\nProxy-Authorization: Basic {s}\r\n\r\n",
        .{ origin.port, basic },
    );
    try writer.interface.writeAll(request);
    try writer.interface.flush();

    var read_buffer: [512]u8 = undefined;
    var reader = client.reader(io, &read_buffer);
    var response: ["HTTP/1.1 200 Connection Established\r\n\r\n".len]u8 = undefined;
    try reader.interface.readSliceAll(&response);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 Connection Established\r\n\r\n",
        &response,
    );

    try writer.interface.writeAll("not-a-tls-client-hello");
    try writer.interface.flush();
    try origin_worker.await(io);

    try waitForCounter(service, "tls_upstream_handshake_failures", 1);
    try std.testing.expectEqual(@as(u64, 0), service.metrics().tls_context_failures);
    try std.testing.expectEqual(
        @as(u64, 0),
        service.metrics().tls_downstream_handshake_failures,
    );
    try std.testing.expectEqual(@as(u64, 0), service.metrics().tls_mint_failures);
}

test "a stop wakes a passthrough tunnel whose client and origin keep their connections open" {
    const io = std.testing.io;
    var origin = try listenTestOrigin(io);
    defer origin.listener.deinit(io);

    var fixture: TestServiceFixture = .{};
    try fixture.init(io, std.testing.allocator, &.{});
    defer fixture.deinit();
    const service = fixture.service.?;
    try service.start();

    const proxy_address = try std.Io.net.IpAddress.parse("127.0.0.1", service.clientConfiguration().port);
    const client = try proxy_address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var write_buffer: [512]u8 = undefined;
    var writer = client.writer(io, &write_buffer);
    var raw_buffer: [basic_raw_capacity]u8 = undefined;
    defer std.crypto.secureZero(u8, &raw_buffer);
    var encoded_buffer: [basic_encoded_capacity]u8 = undefined;
    defer std.crypto.secureZero(u8, &encoded_buffer);
    const basic = try encodeBasic(&service.secret, &raw_buffer, &encoded_buffer);
    var request_buffer: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_buffer,
        "CONNECT localhost:{d} HTTP/1.1\r\nProxy-Authorization: Basic {s}\r\n\r\n",
        .{ origin.port, basic },
    );
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    var read_buffer: [512]u8 = undefined;
    var reader = client.reader(io, &read_buffer);
    var response: ["HTTP/1.1 200 Connection Established\r\n\r\n".len]u8 = undefined;
    try reader.interface.readSliceAll(&response);
    const upstream = try origin.listener.accept(io);
    defer upstream.close(io);

    // Neither side closes: only the stop ends both relay directions.
    const started = awakeMs(io);
    try std.testing.expectEqual(TunnelJoin.joined, service.stop());
    try std.testing.expect(awakeMs(io) - started < service_support.stop_timeout_ms);
}

test "a stop leaves a tunnel nothing interrupts behind at its deadline, with the port free for the next service" {
    const io = std.testing.io;
    var gate: TunnelTestGate = .{};
    var fixture: TestServiceFixture = .{
        .tunnel_gate = &gate,
    };
    try fixture.init(io, std.testing.allocator, &.{});
    defer fixture.deinit();
    const service = fixture.service.?;
    try service.start();

    const port = service.clientConfiguration().port;
    const proxy_address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const client = try proxy_address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    try gate.held.wait(io);

    const started = awakeMs(io);
    try std.testing.expectEqual(TunnelJoin.abandoned, service.stop());
    const waited_ms = awakeMs(io) - started;
    try std.testing.expect(waited_ms >= service_support.stop_timeout_ms);
    try std.testing.expect(waited_ms < service_support.stop_timeout_ms + stop_slack_ms);

    // The held tunnel still owns its accepted socket on the port.
    const next = try Service.create(io, std.testing.allocator, fixture.paths(&.{}));
    defer next.destroy();
    try std.testing.expectEqual(port, next.clientConfiguration().port);
    try std.testing.expectEqual(port, next.preferred_port.?);

    gate.released.set(io);
    try std.testing.expectEqual(TunnelJoin.joined, service.stop());
}

/// How far past its deadline a stop may return on a loaded machine.
const stop_slack_ms = 2 * std.time.ms_per_s;

fn awakeMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// The tunnel records its TLS outcome after the origin closed; poll briefly.
fn waitForCounter(service: *const Service, comptime field: []const u8, expected: u64) !void {
    for (0..1000) |_| {
        if (@field(service.metrics(), field) == expected) {
            return;
        }

        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }

    return error.ProxyCounterNotObserved;
}

test "loopback service maps CONNECT authentication and target rejections" {
    const io = std.testing.io;
    var fixture: TestServiceFixture = .{};
    try fixture.init(io, std.testing.allocator, &.{});
    defer fixture.deinit();
    const service = fixture.service.?;
    try service.start();
    defer _ = service.stop();

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", service.clientConfiguration().port);
    const client = try address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var write_buffer: [256]u8 = undefined;
    var writer = client.writer(io, &write_buffer);
    try writer.interface.writeAll("CONNECT api.openai.com:443 HTTP/1.1\r\n\r\n");
    try writer.interface.flush();
    var read_buffer: [512]u8 = undefined;
    var reader = client.reader(io, &read_buffer);
    var response: [512]u8 = undefined;
    const response_len = try reader.interface.readSliceShort(&response);
    try std.testing.expect(std.mem.startsWith(
        u8,
        response[0..response_len],
        "HTTP/1.1 407 Proxy Authentication Required\r\n",
    ));
    try std.testing.expect(std.mem.indexOf(
        u8,
        response[0..response_len],
        "Connection: close\r\n",
    ) != null);
    try std.testing.expectEqual(
        @as(u64, 1),
        service.metrics().invalid_authorization_rejections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        service.metrics().unknown_credential_rejections,
    );

    const unknown_client = try address.connect(io, .{ .mode = .stream });
    defer unknown_client.close(io);
    var unknown_write_buffer: [512]u8 = undefined;
    var unknown_writer = unknown_client.writer(io, &unknown_write_buffer);
    const wrong_secret: identity.Secret = .{0} ** identity.secret_bytes;
    var wrong_raw_buffer: [basic_raw_capacity]u8 = undefined;
    var wrong_encoded_buffer: [basic_encoded_capacity]u8 = undefined;
    const wrong_basic = try encodeBasic(&wrong_secret, &wrong_raw_buffer, &wrong_encoded_buffer);
    var request_buffer: [256]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_buffer,
        "CONNECT api.openai.com:443 HTTP/1.1\r\nProxy-Authorization: Basic {s}\r\n\r\n",
        .{wrong_basic},
    );
    try unknown_writer.interface.writeAll(request);
    try unknown_writer.interface.flush();
    var unknown_read_buffer: [512]u8 = undefined;
    var unknown_reader = unknown_client.reader(io, &unknown_read_buffer);
    var unknown_response: [512]u8 = undefined;
    const unknown_response_len = try unknown_reader.interface.readSliceShort(&unknown_response);
    try std.testing.expect(std.mem.startsWith(
        u8,
        unknown_response[0..unknown_response_len],
        "HTTP/1.1 407 Proxy Authentication Required\r\n",
    ));
    try std.testing.expectEqual(
        @as(u64, 1),
        service.metrics().unknown_credential_rejections,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        service.metrics().rejected_connections,
    );

    var registered_raw_buffer: [basic_raw_capacity]u8 = undefined;
    defer std.crypto.secureZero(u8, &registered_raw_buffer);
    var registered_encoded_buffer: [basic_encoded_capacity]u8 = undefined;
    defer std.crypto.secureZero(u8, &registered_encoded_buffer);
    const registered_basic = try encodeBasic(&service.secret, &registered_raw_buffer, &registered_encoded_buffer);
    const invalid_target_client = try address.connect(io, .{ .mode = .stream });
    defer invalid_target_client.close(io);
    var invalid_target_write_buffer: [512]u8 = undefined;
    var invalid_target_writer = invalid_target_client.writer(io, &invalid_target_write_buffer);
    var invalid_target_request_buffer: [256]u8 = undefined;
    const invalid_target_request = try std.fmt.bufPrint(
        &invalid_target_request_buffer,
        "GET / HTTP/1.1\r\nProxy-Authorization: Basic {s}\r\n\r\n",
        .{registered_basic},
    );
    try invalid_target_writer.interface.writeAll(invalid_target_request);
    try invalid_target_writer.interface.flush();
    var invalid_target_read_buffer: [256]u8 = undefined;
    var invalid_target_reader = invalid_target_client.reader(io, &invalid_target_read_buffer);
    var invalid_target_response: [256]u8 = undefined;
    const invalid_target_response_len = try invalid_target_reader.interface.readSliceShort(&invalid_target_response);
    try std.testing.expect(std.mem.startsWith(
        u8,
        invalid_target_response[0..invalid_target_response_len],
        "HTTP/1.1 400 Bad Request\r\n",
    ));
    try std.testing.expectEqual(
        @as(u64, 2),
        service.metrics().rejected_connections,
    );
}

test "a tunnel whose host never resolves answers 504 at its deadline and frees its row" {
    const io = std.testing.io;
    var fixture: TestServiceFixture = .{};
    try fixture.init(io, std.testing.allocator, &.{});
    defer fixture.deinit();
    const service = fixture.service.?;
    const establish_timeout_ms = 200;

    const started = now(io);
    const client = try sendConnect(service, "silent.test:443");
    defer client.close(io);
    var tunnel = try io.concurrent(service_support.serve, .{
        service,
        client.proxy_side,
        client.slot,
        .{
            .resolutions = &gated_resolver.table,
            .timeout_ms = establish_timeout_ms,
        },
    });

    try expectAnswer(io, client.stream, "HTTP/1.1 504 Gateway Timeout\r\nContent-Length: 0\r\n\r\n");
    try tunnel.await(io);
    const waited_ms = now(io) - started;
    try std.testing.expect(waited_ms >= establish_timeout_ms and waited_ms < 10 * establish_timeout_ms);

    // The row is free while the resolver still holds its worker.
    const metrics = service.metrics();
    try std.testing.expectEqual(@as(u32, 0), metrics.active_connections);
    try std.testing.expectEqual(@as(u64, 1), metrics.establish_timeouts);
    try std.testing.expectEqual(@as(u64, 0), metrics.upstream_connect_failures);
    try std.testing.expectEqual(@as(u32, 1), gated_resolver.table.count(.resolving));

    try gated_resolver.open(&gated_resolver.table);
}

test "a CONNECT that finds every resolution taken is answered 503 at once and frees its row" {
    const io = std.testing.io;
    var fixture: TestServiceFixture = .{};
    try fixture.init(io, std.testing.allocator, &.{});
    defer fixture.deinit();
    const service = fixture.service.?;
    try gated_resolver.fill();

    const started = now(io);
    const client = try sendConnect(service, "one-more.test:443");
    defer client.close(io);
    var tunnel = try io.concurrent(service_support.serve, .{
        service,
        client.proxy_side,
        client.slot,
        .{
            .resolutions = &gated_resolver.table,
            .timeout_ms = Connections.establish_timeout_ms,
        },
    });

    try expectAnswer(io, client.stream, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n");
    try tunnel.await(io);
    try std.testing.expect(now(io) - started < std.time.ms_per_s);

    const metrics = service.metrics();
    try std.testing.expectEqual(@as(u32, 0), metrics.active_connections);
    try std.testing.expectEqual(@as(u64, 1), metrics.resolution_refusals);
    try std.testing.expectEqual(@as(u64, 0), metrics.establish_timeouts);
    try std.testing.expectEqual(Resolutions.capacity, gated_resolver.table.count(.resolving));

    try gated_resolver.open(&gated_resolver.table);
}

test "a CONNECT to an IPv4 address reaches its origin while no name can resolve" {
    const io = std.testing.io;
    var origin = try listenTestOrigin(io);
    defer origin.listener.deinit(io);
    var origin_worker = try io.concurrent(acceptAndClose, .{ io, &origin.listener });
    defer origin_worker.cancel(io) catch {};
    var fixture: TestServiceFixture = .{};
    try fixture.init(io, std.testing.allocator, &.{});
    defer fixture.deinit();
    const service = fixture.service.?;
    try gated_resolver.fill();

    var authority_buffer: [32]u8 = undefined;
    const authority = try std.fmt.bufPrint(&authority_buffer, "127.0.0.1:{d}", .{origin.port});
    const client = try sendConnect(service, authority);
    defer client.close(io);
    var tunnel = try io.concurrent(service_support.serve, .{
        service,
        client.proxy_side,
        client.slot,
        .{
            .resolutions = &gated_resolver.table,
            .timeout_ms = Connections.establish_timeout_ms,
        },
    });

    try expectAnswer(io, client.stream, "HTTP/1.1 200 Connection Established\r\n\r\n");
    // Both ends close, so the relay ends on its own.
    try client.stream.shutdown(io, .both);
    try origin_worker.await(io);
    try tunnel.await(io);
    try std.testing.expectEqual(@as(u32, 0), service.metrics().active_connections);
    try std.testing.expectEqual(@as(u64, 0), service.metrics().resolution_refusals);

    try gated_resolver.open(&gated_resolver.table);
}

test "stopping the service does not wait for a blocked resolution" {
    const io = std.testing.io;
    var fixture: TestServiceFixture = .{};
    try fixture.init(io, std.testing.allocator, &.{});
    defer fixture.deinit();
    const service = fixture.service.?;
    const resolutions = &service_support.resolutions;
    const system_resolver = resolutions.resolver;
    resolutions.resolver = gated_resolver.answerOnceOpen;
    defer resolutions.resolver = system_resolver;
    try service.start();

    const proxy_address = try std.Io.net.IpAddress.parse("127.0.0.1", service.clientConfiguration().port);
    const client = try proxy_address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    try writeConnect(io, client, &service.secret, "silent.test:443");
    try gated_resolver.expectCalls(1);
    try std.testing.expectEqual(@as(u32, 1), service.metrics().active_connections);

    const started = now(io);
    try std.testing.expectEqual(TunnelJoin.joined, service.stop());
    try std.testing.expect(now(io) - started < std.time.ms_per_s);
    try std.testing.expectEqual(@as(u32, 0), service.metrics().active_connections);

    // The worker is still inside the resolver, in a row the service never
    // owned; it frees the row when the resolver returns.
    try std.testing.expectEqual(@as(u32, 1), resolutions.count(.resolving));
    try gated_resolver.open(resolutions);
}

/// One admitted connection over a socket pair, its CONNECT head already
/// sent: the proxy's end with its row, and the client's end.
const ConnectedClient = struct {
    proxy_side: std.Io.net.Stream,
    slot: Connections.Slot,
    stream: std.Io.net.Stream,

    /// Closes the client's end; the tunnel closes the proxy's.
    fn close(self: ConnectedClient, io: std.Io) void {
        self.stream.close(io);
    }
};

fn sendConnect(service: *Service, authority: []const u8) !ConnectedClient {
    const io = std.testing.io;
    var sockets: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets));
    const client: ConnectedClient = .{
        .proxy_side = localStream(sockets[0]),
        .slot = service.connections.acquire(sockets[0], now(io)).?,
        .stream = localStream(sockets[1]),
    };
    try writeConnect(io, client.stream, &service.secret, authority);

    return client;
}

fn localStream(handle: std.c.fd_t) std.Io.net.Stream {
    return .{
        .socket = .{
            .handle = handle,
            .address = .{
                .ip4 = .loopback(0),
            },
        },
    };
}

fn writeConnect(io: std.Io, stream: std.Io.net.Stream, secret: *const identity.Secret, authority: []const u8) !void {
    var raw_buffer: [basic_raw_capacity]u8 = undefined;
    defer std.crypto.secureZero(u8, &raw_buffer);
    var encoded_buffer: [basic_encoded_capacity]u8 = undefined;
    defer std.crypto.secureZero(u8, &encoded_buffer);
    const basic = try encodeBasic(secret, &raw_buffer, &encoded_buffer);

    var write_buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.print("CONNECT {s} HTTP/1.1\r\nProxy-Authorization: Basic {s}\r\n\r\n", .{ authority, basic });
    try writer.interface.flush();
}

fn expectAnswer(io: std.Io, stream: std.Io.net.Stream, comptime expected: []const u8) !void {
    var read_buffer: [256]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var answer: [expected.len]u8 = undefined;
    try reader.interface.readSliceAll(&answer);
    try std.testing.expectEqualStrings(expected, &answer);
}

fn now(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

const TestOrigin = struct { listener: std.Io.net.Server, port: u16 };

const TestServiceFixture = struct {
    temp: std.testing.TmpDir = undefined,
    key: [std.fs.max_path_bytes]u8 = undefined,
    certificate: [std.fs.max_path_bytes]u8 = undefined,
    bundle: [std.fs.max_path_bytes]u8 = undefined,
    secret: [std.fs.max_path_bytes]u8 = undefined,
    port: [std.fs.max_path_bytes]u8 = undefined,
    legacy_port: [std.fs.max_path_bytes]u8 = undefined,
    directory_len: usize = 0,
    service: ?*Service = null,
    tunnel_gate: ?*TunnelTestGate = null,

    pub fn init(self: *TestServiceFixture, io: std.Io, gpa: std.mem.Allocator, intercept_hosts: []const []const u8) !void {
        self.temp = std.testing.tmpDir(.{});
        errdefer self.temp.cleanup();

        var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const directory = directory_buffer[0..try self.temp.dir.realPath(io, &directory_buffer)];
        self.directory_len = (try std.fmt.bufPrint(&self.key, "{s}/ca-key.pem", .{directory})).len;
        _ = try std.fmt.bufPrint(&self.certificate, "{s}/ca-cert.pem", .{directory});
        _ = try std.fmt.bufPrint(&self.bundle, "{s}/ca-bundle.pem", .{directory});
        _ = try std.fmt.bufPrint(&self.secret, "{s}/proxy-secret", .{directory});
        _ = try std.fmt.bufPrint(&self.port, "{s}/proxy-port-test", .{directory});
        _ = try std.fmt.bufPrint(&self.legacy_port, "{s}/proxy-port", .{directory});
        self.service = try Service.create(io, gpa, self.paths(intercept_hosts));
    }

    /// The paths under the fixture's directory; every name shares the
    /// directory prefix and its own suffix.
    pub fn paths(self: *const TestServiceFixture, intercept_hosts: []const []const u8) Paths {
        const directory_len = self.directory_len - "/ca-key.pem".len;
        return .{
            .key = self.key[0 .. directory_len + "/ca-key.pem".len],
            .certificate = self.certificate[0 .. directory_len + "/ca-cert.pem".len],
            .bundle = self.bundle[0 .. directory_len + "/ca-bundle.pem".len],
            .secret = self.secret[0 .. directory_len + "/proxy-secret".len],
            .port = self.port[0 .. directory_len + "/proxy-port-test".len],
            .legacy_port = self.legacy_port[0 .. directory_len + "/proxy-port".len],
            .endpoint = "/test/runtime.sock",
            .intercept_hosts = intercept_hosts,
            .tunnel_gate = self.tunnel_gate,
        };
    }

    pub fn deinit(self: *TestServiceFixture) void {
        if (self.service) |service| {
            service.destroy();
        }

        self.temp.cleanup();
    }
};
