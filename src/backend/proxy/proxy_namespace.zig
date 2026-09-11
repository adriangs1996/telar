//! Runtime-facing proxy capability.
//!
//! Credentials are generated, registered, validated, and erased inside this
//! package. Runtime and pane state only see pane keys and observations.

const ca_module = @import("ca.zig");
const PaneKeyType = @import("../pane/PaneKey.zig");
const middleware = @import("middleware.zig");
const types = @import("../agent/types.zig");
const buffer_support = @import("capture/buffer_support.zig");
const ProxyType = @import("Proxy.zig");
const GenericLifecyclePort = @import("GenericLifecyclePort.zig").Type;
const ServiceType = @import("service/Service.zig");
const service_support = @import("service/service_support.zig");
const GenericLifecycle = @import("GenericLifecycle.zig").Type;
const OverrideType = @import("../pty/Override.zig");
const std = @import("std");
const ProxyTestFiles = @import("ProxyTestFiles.zig");
const pane_module = @import("telar-core").pane;
const connection_admission = @import("connection_admission.zig");
const connect_authentication = @import("connect_authentication.zig");
const root = @import("h2/h2.zig");
const root_module = @import("http/http.zig");
const identity = @import("identity.zig");
const lifecycle_mod = @import("lifecycle.zig");
const observation_queue = @import("observation_queue.zig");
const provider_provider = @import("provider/provider.zig");
const service_mod = @import("service/service_namespace.zig");
const sse = @import("sse.zig");
const tls = @import("tls.zig");
const tls_tunnel = @import("tls_tunnel.zig");

pub const ca = @import("ca.zig");

pub const PaneKey = @import("../pane/PaneKey.zig");
pub const ObservationPhase = middleware.Phase;
pub const ObservationProtocol = middleware.Protocol;
pub const ApiDialect = types.ApiDialect;
pub const CaptureConfig = @import("capture/Config.zig");
pub const CaptureExchange = @import("capture/Exchange.zig");
pub const CaptureHalf = @import("capture/Half.zig");
pub const CaptureJoiner = @import("capture/Joiner.zig");
pub const CaptureOutcome = buffer_support.Outcome;

pub const Config = @import("Config.zig");

pub const Observation = @import("Observation.zig");

pub const MetricsSnapshot = @import("Snapshot.zig");

pub const PaneEnvironment = @import("PaneEnvironment.zig");

pub const PaneEnvironmentOptions = @import("PaneEnvironmentOptions.zig");

const lifecycle_port: GenericLifecyclePort(ServiceType, service_support.Worker) = .{
    .start = ServiceType.start,
    .cancel = ServiceType.cancel,
    .close = ServiceType.close,
    .destroy = ServiceType.destroy,
};

pub const ServiceLifecycle = GenericLifecycle(ServiceType, service_support.Worker, lifecycle_port);

pub const Proxy = @import("Proxy.zig");

pub const environment_override_count = 11;

/// Upper bound on identity variables a pane launch may add before the proxy's
/// own overrides.
pub const max_pane_overrides = 6;

pub fn environmentOverrides(proxy_url: []const u8, certificate_path: []const u8, bundle_path: []const u8) [environment_override_count]OverrideType {
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

fn waitForConnectionMetrics(proxy: *const ProxyType, expected_active: u32, expected_limit_drops: u64) !void {
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
    const proxy = try ProxyType.create(io, gpa, files.config());
    defer proxy.destroy();

    var inherited_map = std.process.Environ.Map.init(gpa);
    defer inherited_map.deinit();
    try inherited_map.put("PATH", "/bin:/usr/bin");
    const inherited_block = try inherited_map.createPosixBlock(gpa, .{});
    defer inherited_block.deinit(gpa);
    const key: PaneKeyType = .{ .id = try pane_module(7), .generation = 2 };
    var environment = try proxy.registerPane(key, .{
        .inherited = .{ .block = inherited_block },
        .overrides = &.{.{ .name = "TELAR_PANE_ID", .value = "7" }},
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
    var proxy: ?*ProxyType = try ProxyType.create(io, gpa, files.config());
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
    const proxy = try ProxyType.create(io, gpa, files.config());
    defer proxy.destroy();

    const address = proxy.address();
    const connection_limit: usize = service_support.max_connections;
    const client_count = connection_limit + 1;
    var clients: [client_count]?std.Io.net.Stream = @splat(null);
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

    try waitForConnectionMetrics(proxy, service_support.max_connections, 0);

    clients[connection_limit] = try address.connect(io, .{ .mode = .stream });
    try waitForConnectionMetrics(proxy, service_support.max_connections, 1);
}

test {
    std.testing.refAllDecls(ca_module);
    std.testing.refAllDecls(connection_admission);
    std.testing.refAllDecls(connect_authentication);
    std.testing.refAllDecls(root);
    std.testing.refAllDecls(root_module);
    std.testing.refAllDecls(identity);
    std.testing.refAllDecls(lifecycle_mod);
    std.testing.refAllDecls(middleware);
    std.testing.refAllDecls(observation_queue);
    std.testing.refAllDecls(provider_provider);
    std.testing.refAllDecls(service_mod);
    std.testing.refAllDecls(sse);
    std.testing.refAllDecls(tls);
    std.testing.refAllDecls(tls_tunnel);
}
