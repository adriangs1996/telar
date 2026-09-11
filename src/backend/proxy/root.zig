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
const capture_mod = @import("capture/root.zig");
const service_mod = @import("service/root.zig");

pub const ca = @import("ca.zig");

pub const Io = std.Io;

pub const PaneKey = pane_mod.PaneKey;
pub const ObservationPhase = middleware.Phase;
pub const ObservationProtocol = middleware.Protocol;
pub const ApiDialect = middleware.ApiDialect;
pub const CaptureConfig = capture_mod.Config;
pub const CaptureExchange = capture_mod.Exchange;
pub const CaptureHalf = capture_mod.Half;
pub const CaptureJoiner = capture_mod.Joiner;
pub const CaptureOutcome = capture_mod.Outcome;

pub const Config = @import("Config.zig");

pub const Observation = @import("Observation.zig");

pub const MetricsSnapshot = metrics_mod.Snapshot;

pub const PaneEnvironment = @import("PaneEnvironment.zig");

pub const PaneEnvironmentOptions = @import("PaneEnvironmentOptions.zig");

const lifecycle_port: lifecycle_mod.Port(service_mod.Service, service_mod.Worker) = .{
    .start = service_mod.Service.start,
    .cancel = service_mod.Service.cancel,
    .close = service_mod.Service.close,
    .destroy = service_mod.Service.destroy,
};

pub const ServiceLifecycle = lifecycle_mod.Lifecycle(service_mod.Service, service_mod.Worker, lifecycle_port);

pub const Proxy = @import("Proxy.zig");

pub const environment_override_count = 11;

/// Upper bound on identity variables a pane launch may add before the proxy's
/// own overrides.
pub const max_pane_overrides = 6;

pub fn environmentOverrides(proxy_url: []const u8, certificate_path: []const u8, bundle_path: []const u8) [environment_override_count]pty.ChildEnvironment.Override {
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

const ProxyTestFiles = @import("ProxyTestFiles.zig");

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
