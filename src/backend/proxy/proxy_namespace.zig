//! Runtime-facing proxy capability.
//!
//! The proxy secret is read, created and compared inside this package. The
//! runtime only asks for a child environment and receives captured halves.

const core = @import("telar-core");
const Service = @import("service/Service.zig");
const service_support = @import("service/service_support.zig");
const pty = @import("pty");
const Override = pty.Override;
const std = @import("std");
const connect_authentication = @import("connect_authentication.zig");
const identity = @import("identity.zig");
const service_mod = @import("service/service_namespace.zig");
const localca = @import("localca");
const tls = localca.tls;

const ca = localca.ca;

pub const PaneKey = @import("../pane/PaneKey.zig");

pub const Config = @import("Config.zig");

pub const Protocol = @import("Protocol.zig").Protocol;

pub const PaneEnvironment = @import("PaneEnvironment.zig");

pub const PaneEnvironmentOptions = @import("PaneEnvironmentOptions.zig");

pub const Proxy = @import("Proxy.zig");

pub const environment_override_count = 11;

/// Upper bound on identity variables a pane launch may add before the proxy's
/// own overrides.
pub const max_pane_overrides = 6;

pub fn environmentOverrides(proxy_url: []const u8, certificate_path: []const u8, bundle_path: []const u8) [environment_override_count]Override {
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

test "every pane environment carries the same secret proxy URL and disposes itself" {
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
    var first = try proxy.environment(.{
        .inherited = .{ .block = inherited_block },
        .overrides = &.{.{ .name = "TELAR_PANE_ID", .value = "7" }},
    });
    defer first.deinit();
    var second = try proxy.environment(.{
        .inherited = .{ .block = inherited_block },
        .overrides = &.{.{ .name = "TELAR_PANE_ID", .value = "8" }},
    });
    defer second.deinit();
    const first_child: std.process.Environ = .{ .block = first.environment().block };
    const second_child: std.process.Environ = .{ .block = second.environment().block };
    const first_url = std.process.Environ.getPosix(first_child, "HTTPS_PROXY").?;
    try std.testing.expect(std.mem.startsWith(u8, first_url, "http://telar:"));
    try std.testing.expectEqual(@as(usize, "http://telar:".len + identity.secret_bytes * 2 + "@127.0.0.1:".len), std.mem.lastIndexOfScalar(u8, first_url, ':').? + 1);
    try std.testing.expectEqualStrings(first_url, std.process.Environ.getPosix(second_child, "HTTPS_PROXY").?);
    try std.testing.expectEqualStrings("8", std.process.Environ.getPosix(second_child, "TELAR_PANE_ID").?);
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
    std.testing.refAllDecls(ca);
    _ = @import("Slots.zig");
    _ = @import("capture/capture_tests.zig");
    _ = @import("tunnel/tunnel_namespace.zig");
    _ = @import("tunnel/EventObserver.zig");
    _ = @import("tunnel/RelayContext.zig");
    _ = @import("tunnel/Http1Connection.zig");
    _ = @import("tunnel/Establisher.zig");
    _ = @import("metrics.zig");
    std.testing.refAllDecls(connect_authentication);
    std.testing.refAllDecls(identity);
    std.testing.refAllDecls(service_mod);
    std.testing.refAllDecls(tls);
    _ = core;
}

const ProxyTestFiles = struct {
    temp: std.testing.TmpDir,
    key: [std.fs.max_path_bytes]u8 = undefined,
    key_len: usize = 0,
    certificate: [std.fs.max_path_bytes]u8 = undefined,
    certificate_len: usize = 0,
    bundle: [std.fs.max_path_bytes]u8 = undefined,
    bundle_len: usize = 0,
    secret: [std.fs.max_path_bytes]u8 = undefined,
    secret_len: usize = 0,
    port: [std.fs.max_path_bytes]u8 = undefined,
    port_len: usize = 0,

    pub fn init(io: std.Io) !ProxyTestFiles {
        var files: ProxyTestFiles = .{ .temp = std.testing.tmpDir(.{}) };
        errdefer files.temp.cleanup();

        var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const directory_len = try files.temp.dir.realPath(io, &directory_buffer);
        const directory = directory_buffer[0..directory_len];
        files.key_len = (try std.fmt.bufPrint(&files.key, "{s}/ca-key.pem", .{directory})).len;
        files.certificate_len = (try std.fmt.bufPrint(&files.certificate, "{s}/ca-cert.pem", .{directory})).len;
        files.bundle_len = (try std.fmt.bufPrint(&files.bundle, "{s}/ca-bundle.pem", .{directory})).len;
        files.secret_len = (try std.fmt.bufPrint(&files.secret, "{s}/proxy-secret", .{directory})).len;
        files.port_len = (try std.fmt.bufPrint(&files.port, "{s}/proxy-port", .{directory})).len;

        return files;
    }

    pub fn deinit(self: *ProxyTestFiles) void {
        self.temp.cleanup();
    }

    pub fn config(self: *const ProxyTestFiles) Config {
        return .{
            .key_path = self.key[0..self.key_len],
            .certificate_path = self.certificate[0..self.certificate_len],
            .bundle_path = self.bundle[0..self.bundle_len],
            .secret_path = self.secret[0..self.secret_len],
            .port_path = self.port[0..self.port_len],
        };
    }
};
