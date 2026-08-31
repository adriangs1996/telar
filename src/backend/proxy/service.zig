//! Runtime-owned loopback ProxyTLS service.

const std = @import("std");
const core = @import("telar-core");
const diagnostics = core.diagnostics;
const ca = @import("ca.zig");
const connection_admission = @import("connection_admission.zig");
const credential_registry = @import("credential_registry.zig");
const identity = @import("identity.zig");
const metrics_mod = @import("metrics.zig");
const middleware = @import("middleware.zig");
const observation_queue = @import("observation_queue.zig");
const passthrough_policy = @import("passthrough_policy.zig");
const provider = @import("provider/root.zig");
const tls = @import("tls.zig");
const tunnel_mod = @import("tunnel/root.zig");

const Io = std.Io;
const net = Io.net;
const schema = core.schema;

pub const first_port: u16 = 45100;
pub const port_attempts: u16 = 128;
pub const max_connections: u32 = 64;
pub const event_capacity = observation_queue.capacity;

pub const Paths = struct {
    key: []const u8,
    certificate: []const u8,
    bundle: []const u8,
    passthrough_hosts: []const []const u8 = &.{},
};

pub const Pane = struct {
    id: schema.PaneId,
    generation: u64,
};

pub const ClientConfiguration = struct {
    port: u16,
    certificate_path: []const u8,
    bundle_path: []const u8,
};

pub const Worker = Io.Future(anyerror!void);

pub const Service = struct {
    io: Io,
    gpa: std.mem.Allocator,
    listener: net.Server,
    port: u16,
    authority: ca.Authority,
    roots: tls.Roots,
    certificate_path: []const u8,
    bundle_path: []const u8,
    passthrough_hosts: passthrough_policy.Policy,
    credentials: credential_registry.Registry = .{},
    pipeline: middleware.Pipeline = .{},
    transforms: middleware.TransformPipeline = .{},
    has_custom_transformers: bool = false,
    configuration_mutex: Io.Mutex = .init,
    started: bool = false,
    observations: observation_queue.Channel = undefined,
    connection_slots: connection_admission.Slots = .init(max_connections),
    telemetry: metrics_mod.Counters = .{},
    next_connection_id: std.atomic.Value(u64) = .init(1),

    pub fn create(io: Io, gpa: std.mem.Allocator, paths: Paths) !*Service {
        const ca_resources: ca.Resources = .{ .io = io, .allocator = gpa };
        var authority = try ca.Authority.loadOrCreate(ca_resources, .{
            .key = paths.key,
            .certificate = paths.certificate,
        });
        defer std.crypto.secureZero(u8, std.mem.asBytes(&authority));
        try authority.writeBundle(ca_resources, paths.bundle);
        var roots = try tls.Roots.load(io, gpa);
        errdefer roots.deinit(gpa);
        var bound = try listen(io);
        errdefer bound.listener.deinit(io);
        const service = try gpa.create(Service);
        errdefer gpa.destroy(service);
        service.* = .{
            .io = io,
            .gpa = gpa,
            .listener = bound.listener,
            .port = bound.port,
            .authority = authority,
            .roots = roots,
            .certificate_path = paths.certificate,
            .bundle_path = paths.bundle,
            .passthrough_hosts = try .init(paths.passthrough_hosts),
            .observations = undefined,
        };
        service.observations.init(.{
            .context = service,
            .is_live = observationCredentialIsLive,
        });
        try service.pipeline.add(service.observations.observer());
        try service.transforms.add(provider.claudeRequestTransformer());
        return service;
    }

    /// Releases the stopped service and scrubs its in-memory authority and
    /// credentials. Call `cancel` and `close` before destroying a started
    /// service.
    ///
    /// ```zig
    /// service.destroy();
    /// ```
    pub fn destroy(service: *Service) void {
        const gpa = service.gpa;
        service.listener.deinit(service.io);
        service.roots.deinit(gpa);
        std.crypto.secureZero(u8, std.mem.asBytes(service));
        gpa.destroy(service);
    }

    /// Starts the listener worker. The returned worker owns the running accept
    /// loop until it is passed to `cancel`.
    ///
    /// ```zig
    /// var worker = try service.start();
    /// defer service.cancel(&worker);
    /// ```
    pub fn start(service: *Service) !Worker {
        return service.io.concurrent(run, .{service});
    }

    /// Cancels and joins the listener worker before service resources are
    /// released.
    ///
    /// ```zig
    /// service.cancel(&worker);
    /// ```
    pub fn cancel(service: *Service, worker: *Worker) void {
        _ = worker.cancel(service.io) catch {};
    }

    /// Closes observation delivery after the listener worker has stopped.
    ///
    /// ```zig
    /// service.close();
    /// ```
    pub fn close(service: *Service) void {
        service.observations.close(service.io);
    }

    /// Returns the stable connection and trust configuration inherited by
    /// children registered with this service.
    ///
    /// ```zig
    /// const client = service.clientConfiguration();
    /// ```
    pub fn clientConfiguration(service: *const Service) ClientConfiguration {
        return .{
            .port = service.port,
            .certificate_path = service.certificate_path,
            .bundle_path = service.bundle_path,
        };
    }

    fn run(service: *Service) anyerror!void {
        const path = diagnostics.enter(.observation);
        defer path.restore();
        service.configuration_mutex.lockUncancelable(service.io);
        if (service.started) {
            service.configuration_mutex.unlock(service.io);
            return error.ProxyAlreadyRunning;
        }
        service.started = true;
        service.configuration_mutex.unlock(service.io);

        return ConnectionAdmission.run(service);
    }

    /// Waits for the next live observation. Events for credentials revoked
    /// while queued are discarded before this method returns.
    ///
    /// ```zig
    /// var event = try service.receive(io);
    /// defer std.crypto.secureZero(u8, &event.credential.token);
    /// ```
    pub fn receive(service: *Service, io: Io) anyerror!middleware.Event {
        return service.observations.receive(io);
    }

    /// Returns one lock-free snapshot without exposing queue, admission, or
    /// counter storage to the caller.
    ///
    /// ```zig
    /// const snapshot = service.metrics();
    /// ```
    pub fn metrics(service: *const Service) metrics_mod.Snapshot {
        return service.telemetry.snapshot(.{
            .connections = service.connection_slots.snapshot(),
            .observations = service.observations.metrics(),
        });
    }

    /// Formats the loopback proxy URL for a credential into caller-owned
    /// storage.
    ///
    /// ```zig
    /// const url = try service.credentialUrl(&buffer, &credential);
    /// ```
    pub fn credentialUrl(service: *const Service, buffer: []u8, credential: *const identity.Credential) ![]const u8 {
        return identity.formatUrl(buffer, service.port, credential);
    }

    /// Creates and registers a fresh capability for one pane generation. The
    /// caller owns the returned secret and must scrub it after use.
    ///
    /// ```zig
    /// var credential = try service.registerPane(.{ .id = pane_id, .generation = 2 });
    /// defer std.crypto.secureZero(u8, &credential.token);
    /// ```
    pub fn registerPane(service: *Service, pane: Pane) !identity.Credential {
        var credential: identity.Credential = .{
            .pane_id = pane.id,
            .pane_generation = pane.generation,
            .token = identity.randomToken(service.io),
        };
        errdefer std.crypto.secureZero(u8, &credential.token);

        try service.registerCredential(&credential);

        return credential;
    }

    /// Credentials are live capabilities, not merely well-formed proxy URL
    /// userinfo. Registration and revocation follow the pane lifecycle.
    ///
    /// ```zig
    /// try service.registerCredential(&credential);
    /// ```
    pub fn registerCredential(service: *Service, credential: *const identity.Credential) !void {
        return service.credentials.register(service.io, credential);
    }

    /// Revokes one exact credential, including rollback of an incomplete pane
    /// registration.
    ///
    /// ```zig
    /// service.unregisterCredential(&credential);
    /// ```
    pub fn unregisterCredential(service: *Service, credential: *const identity.Credential) void {
        service.credentials.remove(service.io, credential);
    }

    /// Revokes every credential issued for one exact pane generation.
    ///
    /// ```zig
    /// service.unregisterPane(.{ .id = pane_id, .generation = 2 });
    /// ```
    pub fn unregisterPane(service: *Service, pane: Pane) void {
        service.credentials.removePane(service.io, .{ .id = pane.id, .generation = pane.generation });
    }

    /// Register before `run` starts. The immutable pipeline can later be
    /// backed by a bounded worker without giving it access to tunnel state.
    ///
    /// ```zig
    /// try service.addTransformer(transformer);
    /// ```
    pub fn addTransformer(service: *Service, transformer: middleware.Transformer) !void {
        service.configuration_mutex.lockUncancelable(service.io);
        defer service.configuration_mutex.unlock(service.io);
        if (service.started) {
            return error.ProxyAlreadyRunning;
        }

        try service.transforms.add(transformer);
        service.has_custom_transformers = true;
    }
};

const connection_admission_port: connection_admission.Port(Service, net.Stream) = .{
    .accept = acceptConnection,
    .acquire = acquireConnection,
    .start = startConnection,
    .release = releaseConnection,
    .close = closeConnection,
    .cancel = cancelConnections,
};

const ConnectionAdmission = connection_admission.Runner(Service, net.Stream, connection_admission_port);

fn acceptConnection(service: *Service) !net.Stream {
    return service.listener.accept(service.io);
}

fn acquireConnection(service: *Service) bool {
    return service.connection_slots.acquire();
}

fn startConnection(service: *Service, connections: *Io.Group, stream: net.Stream) !void {
    try connections.concurrent(service.io, serveConnection, .{ service, stream });
}

fn serveConnection(service: *Service, stream: net.Stream) Io.Cancelable!void {
    defer service.connection_slots.release();

    var tunnel = tunnel_mod.Tunnel.init(.{
        .dependencies = .{
            .tls = .{
                .io = service.io,
                .gpa = service.gpa,
                .authority = &service.authority,
                .roots = &service.roots,
                .passthrough = &service.passthrough_hosts,
                .telemetry = &service.telemetry,
            },
            .credentials = &service.credentials,
            .pipeline = &service.pipeline,
            .transforms = &service.transforms,
            .has_custom_transformers = service.has_custom_transformers,
            .connection_ids = &service.next_connection_id,
        },
        .child = stream,
    });

    return tunnel.run();
}

fn releaseConnection(service: *Service) void {
    service.connection_slots.release();
}

fn closeConnection(service: *Service, stream: net.Stream) void {
    stream.close(service.io);
}

fn cancelConnections(service: *Service, connections: *Io.Group) void {
    connections.cancel(service.io);
}

fn observationCredentialIsLive(context: *anyopaque, credential: *const identity.Credential) bool {
    const service: *Service = @ptrCast(@alignCast(context));
    return service.credentials.contains(service.io, credential);
}

const Bound = struct { listener: net.Server, port: u16 };

fn listen(io: Io) !Bound {
    var port = first_port;
    while (port < first_port + port_attempts) : (port += 1) {
        const address = net.IpAddress.parse("127.0.0.1", port) catch unreachable;
        const listener = address.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => continue,
            else => |other| return other,
        };
        return .{ .listener = listener, .port = port };
    }
    return error.ProxyPortUnavailable;
}

test "proxy listeners own distinct loopback ports" {
    const io = std.testing.io;
    var first = try listen(io);
    defer first.listener.deinit(io);
    var second = try listen(io);
    defer second.listener.deinit(io);
    try std.testing.expect(first.port != second.port);
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

    const changed = service.transforms.apply(.{
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

fn listenTestOrigin(io: Io) !Bound {
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
    const credential: identity.Credential = .{
        .pane_id = try schema.id.pane(7),
        .pane_generation = 12,
        .token = .{0x11} ** identity.token_bytes,
    };
    try service.registerCredential(&credential);
    const observation: middleware.Event = .{
        .credential = credential,
        .provider = .codex,
        .phase = .response_activity,
        .protocol = .http11,
        .connection_id = 1,
        .observed_at_ms = 1,
    };
    for (0..event_capacity) |_| service.pipeline.publish(io, observation);
    service.pipeline.publish(io, observation);
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

    const proxy_address = try net.IpAddress.parse("127.0.0.1", service.port);
    const client = try proxy_address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var write_buffer: [512]u8 = undefined;
    var writer = client.writer(io, &write_buffer);
    const raw = "telar:7.12.11111111111111111111111111111111";
    var encoded: [std.base64.standard.Encoder.calcSize(raw.len)]u8 = undefined;
    const basic = std.base64.standard.Encoder.encode(&encoded, raw);
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

    const credential: identity.Credential = .{
        .pane_id = try schema.id.pane(9),
        .pane_generation = 4,
        .token = .{0x22} ** identity.token_bytes,
    };
    try service.registerCredential(&credential);
    var worker = try service.start();
    defer service.cancel(&worker);

    const proxy_address = try net.IpAddress.parse("127.0.0.1", service.port);
    const client = try proxy_address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var write_buffer: [512]u8 = undefined;
    var writer = client.writer(io, &write_buffer);
    const raw = "telar:9.4.22222222222222222222222222222222";
    var encoded: [std.base64.standard.Encoder.calcSize(raw.len)]u8 = undefined;
    const basic = std.base64.standard.Encoder.encode(&encoded, raw);
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

    const current: identity.Credential = .{
        .pane_id = try schema.id.pane(7),
        .pane_generation = 2,
        .token = .{0x5a} ** identity.token_bytes,
    };
    const next: identity.Credential = .{
        .pane_id = current.pane_id,
        .pane_generation = 3,
        .token = .{0x6b} ** identity.token_bytes,
    };
    try service.registerCredential(&current);
    service.pipeline.publish(io, .{
        .credential = current,
        .provider = .codex,
        .phase = .request_started,
        .protocol = .http11,
        .connection_id = 1,
        .observed_at_ms = 1,
    });
    service.unregisterPane(.{ .id = current.pane_id, .generation = current.pane_generation });
    try service.registerCredential(&next);
    service.pipeline.publish(io, .{
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

    const address = try net.IpAddress.parse("127.0.0.1", service.port);
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

    var credential = identity.parseProxyAuthorization(request).?;
    defer std.crypto.secureZero(u8, &credential.token);
    try service.registerCredential(&credential);
    const invalid_target_client = try address.connect(io, .{ .mode = .stream });
    defer invalid_target_client.close(io);
    var invalid_target_write_buffer: [512]u8 = undefined;
    var invalid_target_writer = invalid_target_client.writer(io, &invalid_target_write_buffer);
    var invalid_target_request_buffer: [256]u8 = undefined;
    const invalid_target_request = try std.fmt.bufPrint(
        &invalid_target_request_buffer,
        "GET / HTTP/1.1\r\nProxy-Authorization: Basic {s}\r\n\r\n",
        .{basic},
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
