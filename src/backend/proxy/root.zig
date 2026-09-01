//! Runtime-facing proxy capability.
//!
//! Credentials are generated, registered, validated, and erased inside this
//! package. Runtime and pane state only see pane keys and observations.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../pane/root.zig");
const pty = @import("../pty/root.zig");
const lifecycle_mod = @import("lifecycle.zig");
const metrics_mod = @import("metrics.zig");
const middleware = @import("middleware.zig");
const service_mod = @import("service/root.zig");

const Io = std.Io;

pub const PaneKey = pane_mod.PaneKey;
pub const ObservationPhase = middleware.Phase;
pub const ObservationProtocol = middleware.Protocol;

pub const Config = struct {
    key_path: []const u8,
    certificate_path: []const u8,
    bundle_path: []const u8,
    passthrough_hosts: []const []const u8 = &.{},
};

pub const Observation = struct {
    pane: PaneKey,
    provider: core.schema.AgentProvider,
    phase: ObservationPhase,
    protocol: ObservationProtocol,
    connection_id: u64,
    stream_id: u32 = 0,
    status_code: u16 = 0,
    observed_at_ms: i64,
};

pub const MetricsSnapshot = metrics_mod.Snapshot;

/// Ephemeral child environment. Its proxy credential is scrubbed by
/// `pty.ChildEnvironment.deinit`; the runtime must not retain or inspect it.
pub const PaneEnvironment = struct {
    value: pty.ChildEnvironment,

    /// Borrows the environment while this owner remains alive.
    ///
    /// ```zig
    /// const child_environment = pane_environment.environment();
    /// ```
    pub fn environment(pane_environment: *const PaneEnvironment) *const pty.ChildEnvironment {
        return &pane_environment.value;
    }

    /// Scrubs and releases the ephemeral child environment.
    ///
    /// ```zig
    /// pane_environment.deinit();
    /// ```
    pub fn deinit(pane_environment: *PaneEnvironment) void {
        pane_environment.value.deinit();
    }
};

const lifecycle_port: lifecycle_mod.Port(service_mod.Service, service_mod.Worker) = .{
    .start = service_mod.Service.start,
    .cancel = service_mod.Service.cancel,
    .close = service_mod.Service.close,
    .destroy = service_mod.Service.destroy,
};

const ServiceLifecycle = lifecycle_mod.Lifecycle(service_mod.Service, service_mod.Worker, lifecycle_port);

pub const Proxy = struct {
    gpa: std.mem.Allocator,
    lifecycle: ServiceLifecycle,

    /// Creates and starts the complete proxy capability.
    ///
    /// ```zig
    /// const proxy = try Proxy.create(io, gpa, config);
    /// defer proxy.destroy();
    /// ```
    pub fn create(io: Io, gpa: std.mem.Allocator, config: Config) !*Proxy {
        const proxy = try gpa.create(Proxy);
        errdefer gpa.destroy(proxy);

        const service = try service_mod.Service.create(io, gpa, .{
            .key = config.key_path,
            .certificate = config.certificate_path,
            .bundle = config.bundle_path,
            .passthrough_hosts = config.passthrough_hosts,
        });

        proxy.* = .{
            .gpa = gpa,
            .lifecycle = try ServiceLifecycle.start(service),
        };

        return proxy;
    }

    /// Cancels proxy traffic, closes observation delivery, and releases the
    /// capability. The caller must first cancel its outstanding `receive`
    /// operations.
    ///
    /// ```zig
    /// proxy.destroy();
    /// ```
    pub fn destroy(proxy: *Proxy) void {
        const gpa = proxy.gpa;
        proxy.lifecycle.deinit();
        gpa.destroy(proxy);
    }

    /// Registers one pane generation and returns its owned child environment.
    /// `pane_overrides` carries the pane's identity variables; the proxy adds
    /// its own credentials and trust configuration after them.
    ///
    /// ```zig
    /// var pane_environment = try proxy.registerPane(key, inherited, pane_overrides);
    /// defer pane_environment.deinit();
    /// ```
    pub fn registerPane(proxy: *Proxy, key: PaneKey, inherited: std.process.Environ, pane_overrides: []const pty.ChildEnvironment.Override) !PaneEnvironment {
        std.debug.assert(pane_overrides.len <= max_pane_overrides);
        const service = proxy.lifecycle.service;
        var credential = try service.registerPane(.{ .id = key.id, .generation = key.generation });
        defer std.crypto.secureZero(u8, &credential.token);
        errdefer service.unregisterCredential(&credential);

        var url_buffer: [256]u8 = undefined;
        defer std.crypto.secureZero(u8, &url_buffer);
        const proxy_url = try service.credentialUrl(&url_buffer, &credential);
        const client = service.clientConfiguration();
        const proxy_overrides = environmentOverrides(
            proxy_url,
            client.certificate_path,
            client.bundle_path,
        );
        var overrides: [max_pane_overrides + environment_override_count]pty.ChildEnvironment.Override = undefined;
        @memcpy(overrides[0..pane_overrides.len], pane_overrides);
        @memcpy(overrides[pane_overrides.len .. pane_overrides.len + proxy_overrides.len], &proxy_overrides);
        return .{ .value = try pty.ChildEnvironment.initWithOverrides(proxy.gpa, inherited, .{
            .telar_term_program = "telar",
            .overrides = overrides[0 .. pane_overrides.len + proxy_overrides.len],
        }) };
    }

    /// Revokes new tunnels and observations for one exact pane generation.
    ///
    /// ```zig
    /// proxy.revokePane(key);
    /// ```
    pub fn revokePane(proxy: *Proxy, key: PaneKey) void {
        proxy.lifecycle.service.unregisterPane(.{ .id = key.id, .generation = key.generation });
    }

    /// Revocation rejects new tunnels and filters both queued and subsequent
    /// observations. A tunnel already authenticated keeps forwarding bytes.
    ///
    /// ```zig
    /// const observation = try proxy.receive(io);
    /// ```
    pub fn receive(proxy: *Proxy, io: Io) anyerror!Observation {
        var event = try proxy.lifecycle.service.receive(io);
        defer std.crypto.secureZero(u8, &event.credential.token);
        return .{
            .pane = .{
                .id = event.credential.pane_id,
                .generation = event.credential.pane_generation,
            },
            .provider = event.provider,
            .phase = event.phase,
            .protocol = event.protocol,
            .connection_id = event.connection_id,
            .stream_id = event.stream_id,
            .status_code = event.status_code,
            .observed_at_ms = event.observed_at_ms,
        };
    }

    /// Returns a lock-free snapshot of proxy counters.
    ///
    /// ```zig
    /// const snapshot = proxy.metrics();
    /// ```
    pub fn metrics(proxy: *const Proxy) MetricsSnapshot {
        return proxy.lifecycle.service.metrics();
    }

    fn address(proxy: *const Proxy) Io.net.IpAddress {
        const client = proxy.lifecycle.service.clientConfiguration();

        return Io.net.IpAddress.parse("127.0.0.1", client.port) catch unreachable;
    }
};

const environment_override_count = 11;

/// Upper bound on identity variables a pane launch may add before the proxy's
/// own overrides.
pub const max_pane_overrides = 4;

fn environmentOverrides(proxy_url: []const u8, certificate_path: []const u8, bundle_path: []const u8) [environment_override_count]pty.ChildEnvironment.Override {
    return .{
        .{ .name = "HTTPS_PROXY", .value = proxy_url },
        .{ .name = "https_proxy", .value = proxy_url },
        .{ .name = "NODE_USE_ENV_PROXY", .value = "1" },
        .{ .name = "NODE_EXTRA_CA_CERTS", .value = certificate_path },
        .{ .name = "SSL_CERT_FILE", .value = bundle_path },
        .{ .name = "CURL_CA_BUNDLE", .value = bundle_path },
        .{ .name = "REQUESTS_CA_BUNDLE", .value = bundle_path },
        .{ .name = "AWS_CA_BUNDLE", .value = bundle_path },
        .{ .name = "GIT_SSL_CAINFO", .value = bundle_path },
        .{ .name = "CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE", .value = bundle_path },
        .{ .name = "TELAR_PROXY_TLS", .value = "1" },
    };
}

const ProxyTestFiles = struct {
    temp: std.testing.TmpDir,
    key: [std.fs.max_path_bytes]u8 = undefined,
    key_len: usize = 0,
    certificate: [std.fs.max_path_bytes]u8 = undefined,
    certificate_len: usize = 0,
    bundle: [std.fs.max_path_bytes]u8 = undefined,
    bundle_len: usize = 0,

    fn init(io: Io) !ProxyTestFiles {
        var files: ProxyTestFiles = .{ .temp = std.testing.tmpDir(.{}) };
        errdefer files.temp.cleanup();

        var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const directory_len = try files.temp.dir.realPath(io, &directory_buffer);
        const directory = directory_buffer[0..directory_len];
        files.key_len = (try std.fmt.bufPrint(&files.key, "{s}/ca-key.pem", .{directory})).len;
        files.certificate_len = (try std.fmt.bufPrint(&files.certificate, "{s}/ca-cert.pem", .{directory})).len;
        files.bundle_len = (try std.fmt.bufPrint(&files.bundle, "{s}/ca-bundle.pem", .{directory})).len;

        return files;
    }

    fn deinit(files: *ProxyTestFiles) void {
        files.temp.cleanup();
    }

    fn config(files: *const ProxyTestFiles) Config {
        return .{
            .key_path = files.key[0..files.key_len],
            .certificate_path = files.certificate[0..files.certificate_len],
            .bundle_path = files.bundle[0..files.bundle_len],
        };
    }
};

fn waitForConnectionMetrics(proxy: *const Proxy, expected_active: u32, expected_limit_drops: u64) !void {
    for (0..1000) |_| {
        const metrics_snapshot = proxy.metrics();

        if (metrics_snapshot.active_connections == expected_active and metrics_snapshot.connection_limit_drops == expected_limit_drops) {
            return;
        }

        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }

    return error.ProxyConnectionMetricsNotObserved;
}

test "proxy environment covers Git and Google Cloud trust stores" {
    const overrides = environmentOverrides(
        "http://127.0.0.1:45100",
        "/state/ca-cert.pem",
        "/state/ca-bundle.pem",
    );
    try std.testing.expectEqualStrings("GIT_SSL_CAINFO", overrides[8].name);
    try std.testing.expectEqualStrings("/state/ca-bundle.pem", overrides[8].value);
    try std.testing.expectEqualStrings("CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE", overrides[9].name);
    try std.testing.expectEqualStrings("/state/ca-bundle.pem", overrides[9].value);
}

test "pane registration owns and disposes its ephemeral environment" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var files = try ProxyTestFiles.init(io);
    defer files.deinit();
    const proxy = try Proxy.create(io, gpa, files.config());
    defer proxy.destroy();

    var inherited_map = std.process.Environ.Map.init(gpa);
    defer inherited_map.deinit();
    try inherited_map.put("PATH", "/bin:/usr/bin");
    const inherited_block = try inherited_map.createPosixBlock(gpa, .{});
    defer inherited_block.deinit(gpa);
    const key: PaneKey = .{ .id = try core.schema.id.pane(7), .generation = 2 };
    var environment = try proxy.registerPane(key, .{ .block = inherited_block }, &.{
        .{ .name = "TELAR_PANE_ID", .value = "7" },
    });
    const child: std.process.Environ = .{ .block = environment.environment().block };
    try std.testing.expect(std.mem.startsWith(
        u8,
        std.process.Environ.getPosix(child, "HTTPS_PROXY").?,
        "http://telar:7.2.",
    ));
    environment.deinit();
    proxy.revokePane(key);
}

test "proxy lifecycle accepts traffic and cancels an active tunnel during destruction" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var files = try ProxyTestFiles.init(io);
    defer files.deinit();
    var proxy: ?*Proxy = try Proxy.create(io, gpa, files.config());
    defer {
        if (proxy) |owned| {
            owned.destroy();
        }
    }

    const address = proxy.?.address();
    const rejected = try address.connect(io, .{ .mode = .stream });
    defer rejected.close(io);
    var rejected_write_buffer: [64]u8 = undefined;
    var rejected_writer = rejected.writer(io, &rejected_write_buffer);
    try rejected_writer.interface.writeAll("GET / HTTP/1.1\r\n\r\n");
    try rejected_writer.interface.flush();
    var rejected_read_buffer: [128]u8 = undefined;
    var rejected_reader = rejected.reader(io, &rejected_read_buffer);
    const expected =
        "HTTP/1.1 407 Proxy Authentication Required\r\n" ++
        "Proxy-Authenticate: Basic realm=\"telar\"\r\n" ++
        "Content-Length: 0\r\n" ++
        "Connection: close\r\n\r\n";
    var response: [expected.len]u8 = undefined;
    try rejected_reader.interface.readSliceAll(&response);
    try std.testing.expectEqualStrings(expected, &response);

    const idle = try address.connect(io, .{ .mode = .stream });
    defer idle.close(io);
    var idle_write_buffer: [64]u8 = undefined;
    var idle_writer = idle.writer(io, &idle_write_buffer);
    try idle_writer.interface.writeAll("CONNECT unfinished");
    try idle_writer.interface.flush();
    try waitForConnectionMetrics(proxy.?, 1, 0);

    proxy.?.destroy();
    proxy = null;
}

test "proxy connection admission enforces the real worker limit" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var files = try ProxyTestFiles.init(io);
    defer files.deinit();
    const proxy = try Proxy.create(io, gpa, files.config());
    defer proxy.destroy();

    const address = proxy.address();
    const connection_limit: usize = service_mod.max_connections;
    const client_count = connection_limit + 1;
    var clients: [client_count]?Io.net.Stream = @splat(null);
    defer {
        for (clients) |client| {
            if (client) |stream| {
                stream.close(io);
            }
        }
    }

    for (clients[0..connection_limit]) |*client| {
        const stream = try address.connect(io, .{ .mode = .stream });
        client.* = stream;
        var write_buffer: [32]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        try writer.interface.writeAll("CONNECT unfinished");
        try writer.interface.flush();
    }

    try waitForConnectionMetrics(proxy, service_mod.max_connections, 0);

    clients[connection_limit] = try address.connect(io, .{ .mode = .stream });
    try waitForConnectionMetrics(proxy, service_mod.max_connections, 1);
}

test {
    std.testing.refAllDecls(@import("ca.zig"));
    std.testing.refAllDecls(@import("connection_admission.zig"));
    std.testing.refAllDecls(@import("connect_authentication.zig"));
    std.testing.refAllDecls(@import("h2/root.zig"));
    std.testing.refAllDecls(@import("http/root.zig"));
    std.testing.refAllDecls(@import("identity.zig"));
    std.testing.refAllDecls(lifecycle_mod);
    std.testing.refAllDecls(middleware);
    std.testing.refAllDecls(@import("observation_queue.zig"));
    std.testing.refAllDecls(@import("provider/root.zig"));
    std.testing.refAllDecls(service_mod);
    std.testing.refAllDecls(@import("sse.zig"));
    std.testing.refAllDecls(@import("tls.zig"));
    std.testing.refAllDecls(@import("tls_tunnel.zig"));
}
