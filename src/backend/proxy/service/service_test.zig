//! Contract and integration tests for the proxy service.

const std = @import("std");
const core = @import("telar-core");
const identity = @import("../identity.zig");
const middleware = @import("../middleware.zig");
const observation_queue = @import("../observation_queue.zig");
const service_mod = @import("service.zig");

const Io = std.Io;
const net = Io.net;
const schema = core.schema;
const event_capacity = observation_queue.capacity;
const Pane = service_mod.Pane;
const Service = service_mod.Service;
const basic_raw_capacity = 128;
const basic_encoded_capacity = std.base64.standard.Encoder.calcSize(basic_raw_capacity);

fn encodeBasic(credential: *const identity.Credential, raw_buffer: *[basic_raw_capacity]u8, encoded_buffer: *[basic_encoded_capacity]u8) ![]const u8 {
    const raw = try std.fmt.bufPrint(raw_buffer, "telar:{d}.{d}.{x}", .{
        schema.id.raw(credential.pane_id),
        credential.pane_generation,
        credential.token,
    });
    const encoded_len = std.base64.standard.Encoder.calcSize(raw.len);

    return std.base64.standard.Encoder.encode(encoded_buffer[0..encoded_len], raw);
}

const TestServiceFixture = struct {
    temp: std.testing.TmpDir = undefined,
    key: [std.fs.max_path_bytes]u8 = undefined,
    certificate: [std.fs.max_path_bytes]u8 = undefined,
    bundle: [std.fs.max_path_bytes]u8 = undefined,
    service: ?*Service = null,

    fn init(fixture: *TestServiceFixture, io: Io, gpa: std.mem.Allocator) !void {
        fixture.temp = std.testing.tmpDir(.{});
        errdefer fixture.temp.cleanup();

        var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const directory_len = try fixture.temp.dir.realPath(io, &directory_buffer);
        const directory = directory_buffer[0..directory_len];
        fixture.service = try Service.create(io, gpa, .{
            .key = try std.fmt.bufPrint(&fixture.key, "{s}/ca-key.pem", .{directory}),
            .certificate = try std.fmt.bufPrint(&fixture.certificate, "{s}/ca-cert.pem", .{directory}),
            .bundle = try std.fmt.bufPrint(&fixture.bundle, "{s}/ca-bundle.pem", .{directory}),
        });
    }

    fn deinit(fixture: *TestServiceFixture) void {
        fixture.service.?.destroy();
        fixture.temp.cleanup();
    }
};

test "pane registration creates one live capability for the requested generation" {
    const io = std.testing.io;
    var fixture: TestServiceFixture = .{};
    try fixture.init(io, std.testing.allocator);
    defer fixture.deinit();
    const service = fixture.service.?;
    const pane: Pane = .{ .id = try schema.id.pane(7), .generation = 3 };

    var credential = try service.registerPane(pane);
    defer std.crypto.secureZero(u8, &credential.token);

    try std.testing.expectEqual(pane.id, credential.pane_id);
    try std.testing.expectEqual(pane.generation, credential.pane_generation);
    try std.testing.expect(service.credentials.contains(io, &credential));

    service.unregisterCredential(&credential);

    try std.testing.expect(!service.credentials.contains(io, &credential));
}

test "service negotiates identity encoding for Claude message requests" {
    var fixture: TestServiceFixture = .{};
    try fixture.init(std.testing.io, std.testing.allocator);
    defer fixture.deinit();
    const service = fixture.service.?;
    var headers: middleware.Headers = .{};
    try headers.append(.{ .name = ":method", .value = "POST" });
    try headers.append(.{ .name = ":path", .value = "/v1/messages" });
    try headers.append(.{ .name = "accept-encoding", .value = "gzip, br" });

    const changed = service.configuration.view().transforms.apply(.{
        .io = std.testing.io,
        .context = .{
            .pane_id = @enumFromInt(1),
            .pane_generation = 1,
            .provider = .claude,
            .protocol = .http11,
            .direction = .request,
            .kind = .request,
            .connection_id = 1,
            .stream_id = 0,
        },
        .headers = &headers,
    });

    try std.testing.expect(changed);
    try std.testing.expectEqualStrings("identity", headers.find("accept-encoding").?);
}

fn echoOpaquePayload(io: Io, listener: *net.Server, expected: []const u8) !void {
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

fn rejectTlsHandshake(io: Io, listener: *net.Server) !void {
    const stream = try listener.accept(io);
    defer stream.close(io);

    var write_buffer: [32]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(&.{ 0x16, 0x03, 0x03, 0xff, 0xff });
    try writer.interface.flush();
}

const TestOrigin = struct { listener: net.Server, port: u16 };

fn listenTestOrigin(io: Io) !TestOrigin {
    var port: u16 = 49_152;
    while (port < 49_280) : (port += 1) {
        const address = net.IpAddress.parse("127.0.0.1", port) catch unreachable;
        const listener = address.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => continue,
            else => |other| return other,
        };
        return .{ .listener = listener, .port = port };
    }
    return error.TestOriginPortUnavailable;
}

test "passthrough CONNECT relays bytes with a saturated observation queue" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const payload = "not-a-tls-client-hello";
    var origin = try listenTestOrigin(io);
    defer origin.listener.deinit(io);
    var origin_worker = try io.concurrent(echoOpaquePayload, .{ io, &origin.listener, payload });
    defer origin_worker.cancel(io) catch {};

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var key_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var cert_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var bundle_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const service = try Service.create(io, gpa, .{
        .key = try std.fmt.bufPrint(&key_buffer, "{s}/ca-key.pem", .{directory}),
        .certificate = try std.fmt.bufPrint(&cert_buffer, "{s}/ca-cert.pem", .{directory}),
        .bundle = try std.fmt.bufPrint(&bundle_buffer, "{s}/ca-bundle.pem", .{directory}),
        .passthrough_hosts = &.{"localhost"},
    });
    defer service.destroy();
    var credential = try service.registerPane(.{ .id = try schema.id.pane(7), .generation = 12 });
    defer std.crypto.secureZero(u8, &credential.token);
    const observation: middleware.Event = .{
        .credential = credential,
        .provider = .codex,
        .phase = .response_activity,
        .protocol = .http11,
        .connection_id = 1,
        .observed_at_ms = 1,
    };
    for (0..event_capacity) |_| service.observations.pipeline().publish(io, observation);
    service.observations.pipeline().publish(io, observation);
    const observation_metrics = service.observations.metrics();

    try std.testing.expectEqual(
        @as(u64, event_capacity),
        observation_metrics.queued,
    );
    try std.testing.expectEqual(
        @as(u64, event_capacity),
        observation_metrics.high_water,
    );
    try std.testing.expectEqual(@as(u64, 1), observation_metrics.dropped);
    var worker = try service.start();
    defer service.cancel(&worker);

    const proxy_address = try net.IpAddress.parse("127.0.0.1", service.clientConfiguration().port);
    const client = try proxy_address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var write_buffer: [512]u8 = undefined;
    var writer = client.writer(io, &write_buffer);
    var raw_buffer: [basic_raw_capacity]u8 = undefined;
    defer std.crypto.secureZero(u8, &raw_buffer);
    var encoded_buffer: [basic_encoded_capacity]u8 = undefined;
    defer std.crypto.secureZero(u8, &encoded_buffer);
    const basic = try encodeBasic(&credential, &raw_buffer, &encoded_buffer);
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

test "intercepted CONNECT publishes and counts an upstream TLS failure" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var origin = try listenTestOrigin(io);
    defer origin.listener.deinit(io);
    var origin_worker = try io.concurrent(rejectTlsHandshake, .{ io, &origin.listener });
    defer origin_worker.cancel(io) catch {};

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var key_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var cert_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var bundle_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const service = try Service.create(io, gpa, .{
        .key = try std.fmt.bufPrint(&key_buffer, "{s}/ca-key.pem", .{directory}),
        .certificate = try std.fmt.bufPrint(&cert_buffer, "{s}/ca-cert.pem", .{directory}),
        .bundle = try std.fmt.bufPrint(&bundle_buffer, "{s}/ca-bundle.pem", .{directory}),
    });
    defer service.destroy();

    var credential = try service.registerPane(.{ .id = try schema.id.pane(9), .generation = 4 });
    defer std.crypto.secureZero(u8, &credential.token);
    var worker = try service.start();
    defer service.cancel(&worker);

    const proxy_address = try net.IpAddress.parse("127.0.0.1", service.clientConfiguration().port);
    const client = try proxy_address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var write_buffer: [512]u8 = undefined;
    var writer = client.writer(io, &write_buffer);
    var raw_buffer: [basic_raw_capacity]u8 = undefined;
    defer std.crypto.secureZero(u8, &raw_buffer);
    var encoded_buffer: [basic_encoded_capacity]u8 = undefined;
    defer std.crypto.secureZero(u8, &encoded_buffer);
    const basic = try encodeBasic(&credential, &raw_buffer, &encoded_buffer);
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

    var event = try service.receive(io);
    defer std.crypto.secureZero(u8, &event.credential.token);
    try std.testing.expectEqual(middleware.Phase.request_failed, event.phase);
    try std.testing.expectEqual(middleware.Protocol.http11, event.protocol);
    try std.testing.expectEqual(@as(u32, 0), event.stream_id);
    try std.testing.expect(std.meta.eql(credential, event.credential));
    try std.testing.expectEqual(
        @as(u64, 1),
        service.metrics().tls_upstream_handshake_failures,
    );
    try std.testing.expectEqual(@as(u64, 0), service.metrics().tls_context_failures);
    try std.testing.expectEqual(
        @as(u64, 0),
        service.metrics().tls_downstream_handshake_failures,
    );
    try std.testing.expectEqual(@as(u64, 0), service.metrics().tls_mint_failures);
}

test "receive discards observations queued before pane revocation" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var key_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var cert_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var bundle_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const service = try Service.create(io, gpa, .{
        .key = try std.fmt.bufPrint(&key_buffer, "{s}/ca-key.pem", .{directory}),
        .certificate = try std.fmt.bufPrint(&cert_buffer, "{s}/ca-cert.pem", .{directory}),
        .bundle = try std.fmt.bufPrint(&bundle_buffer, "{s}/ca-bundle.pem", .{directory}),
    });
    defer service.destroy();

    var current = try service.registerPane(.{ .id = try schema.id.pane(7), .generation = 2 });
    defer std.crypto.secureZero(u8, &current.token);
    service.observations.pipeline().publish(io, .{
        .credential = current,
        .provider = .codex,
        .phase = .request_started,
        .protocol = .http11,
        .connection_id = 1,
        .observed_at_ms = 1,
    });
    service.unregisterPane(.{ .id = current.pane_id, .generation = current.pane_generation });
    var next = try service.registerPane(.{ .id = current.pane_id, .generation = 3 });
    defer std.crypto.secureZero(u8, &next.token);
    service.observations.pipeline().publish(io, .{
        .credential = next,
        .provider = .codex,
        .phase = .request_started,
        .protocol = .http11,
        .connection_id = 2,
        .observed_at_ms = 2,
    });

    var received = try service.receive(io);
    defer std.crypto.secureZero(u8, &received.credential.token);
    try std.testing.expect(std.meta.eql(next, received.credential));
    try std.testing.expectEqual(@as(u64, 0), service.observations.metrics().queued);
}

test "loopback service maps CONNECT authentication and target rejections" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var key_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var cert_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var bundle_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const service = try Service.create(io, gpa, .{
        .key = try std.fmt.bufPrint(&key_buffer, "{s}/ca-key.pem", .{directory}),
        .certificate = try std.fmt.bufPrint(&cert_buffer, "{s}/ca-cert.pem", .{directory}),
        .bundle = try std.fmt.bufPrint(&bundle_buffer, "{s}/ca-bundle.pem", .{directory}),
    });
    defer service.destroy();
    var worker = try service.start();
    defer service.cancel(&worker);

    const address = try net.IpAddress.parse("127.0.0.1", service.clientConfiguration().port);
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
    const raw = "telar:7.12.00112233445566778899aabbccddeeff";
    var encoded: [std.base64.standard.Encoder.calcSize(raw.len)]u8 = undefined;
    const basic = std.base64.standard.Encoder.encode(&encoded, raw);
    var request_buffer: [256]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_buffer,
        "CONNECT api.openai.com:443 HTTP/1.1\r\nProxy-Authorization: Basic {s}\r\n\r\n",
        .{basic},
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

    var credential = try service.registerPane(.{ .id = try schema.id.pane(7), .generation = 12 });
    defer std.crypto.secureZero(u8, &credential.token);
    var registered_raw_buffer: [basic_raw_capacity]u8 = undefined;
    defer std.crypto.secureZero(u8, &registered_raw_buffer);
    var registered_encoded_buffer: [basic_encoded_capacity]u8 = undefined;
    defer std.crypto.secureZero(u8, &registered_encoded_buffer);
    const registered_basic = try encodeBasic(&credential, &registered_raw_buffer, &registered_encoded_buffer);
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
