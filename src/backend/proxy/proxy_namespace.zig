//! Runtime-facing proxy capability.
//!
//! The proxy secret is read, created and compared inside this package. The
//! runtime only asks for a child environment and receives captured halves.

const core = @import("telar-core");
const Service = @import("service/Service.zig");
const pty = @import("pty");
const Override = pty.Override;
const std = @import("std");
const connect_authentication = @import("connect_authentication.zig");
const identity = @import("identity.zig");
const service_mod = @import("service/service_namespace.zig");
const Tunnel = @import("tunnel/Tunnel.zig");
const Connections = @import("Connections.zig");
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

test "silent connections fill only the unauthenticated rows, and the oldest past a second makes room" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var files = try ProxyTestFiles.init(io);
    defer files.deinit();
    const proxy = try Proxy.create(io, gpa, files.config());
    defer proxy.destroy();

    const address = proxy.address();
    const silent_count = Connections.max_unauthenticated;
    var clients: [silent_count + 2]?std.Io.net.Stream = @splat(null);
    defer {
        for (clients) |client| {
            if (client) |stream| {
                stream.close(io);
            }
        }
    }

    for (clients[0..silent_count]) |*client| {
        client.* = try address.connect(io, .{
            .mode = .stream,
        });
    }

    try waitForConnectionMetrics(proxy, silent_count, 0);

    clients[silent_count] = try address.connect(io, .{
        .mode = .stream,
    });
    try expectAnswer(io, clients[silent_count].?, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    try std.testing.expectEqual(@as(u64, 1), proxy.metrics().unauthenticated_refusals);

    try io.sleep(.fromMilliseconds(Connections.min_evictable_connect_head_ms + 100), .awake);
    clients[silent_count + 1] = try address.connect(io, .{
        .mode = .stream,
    });
    try waitForMetric(proxy, "unauthenticated_evictions", 1);

    var evicted: usize = 0;
    for (clients[0..silent_count]) |client| {
        var byte: [1]u8 = undefined;
        evicted += @intFromBool(std.c.recv(client.?.socket.handle, &byte, byte.len, std.c.MSG.DONTWAIT) == 0);
    }

    try std.testing.expectEqual(@as(usize, 1), evicted);
    try waitForConnectionMetrics(proxy, silent_count, 0);
}

test "a full table closes a waiting connection to admit a new one, and never one in flight" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var files = try ProxyTestFiles.init(io);
    defer files.deinit();
    const proxy = try Proxy.create(io, gpa, files.config());
    defer proxy.destroy();

    const address = proxy.address();
    const connections = &proxy.service.connections;
    var clients: [Connections.capacity + 2]?std.Io.net.Stream = @splat(null);
    defer {
        for (clients) |client| {
            if (client) |stream| {
                stream.close(io);
            }
        }
    }

    // Admit every row in batches the unauthenticated bound allows, then
    // pretend each batch authenticated and has an exchange in flight.
    var admitted: u32 = 0;
    while (admitted < Connections.capacity) {
        const batch = @min(Connections.max_unauthenticated, Connections.capacity - admitted);
        for (clients[admitted..][0..batch]) |*client| {
            client.* = try address.connect(io, .{
                .mode = .stream,
            });
        }

        admitted += batch;
        try waitForConnectionMetrics(proxy, admitted, 0);
        markInFlight(connections, now(io));
    }

    // One row waits for its next request, long past the idle bound.
    const waiting: Connections.Slot = @enumFromInt(17);
    connections.endExchange(waiting);
    connections.enter(waiting, .idle, now(io) - Connections.min_evictable_idle_ms - 1);

    clients[Connections.capacity] = try address.connect(io, .{
        .mode = .stream,
    });
    try waitForMetric(proxy, "evictions", 1);
    try waitForConnectionMetrics(proxy, Connections.capacity, 0);

    var closed: usize = 0;
    for (clients[0..Connections.capacity]) |client| {
        var byte: [1]u8 = undefined;
        closed += @intFromBool(std.c.recv(client.?.socket.handle, &byte, byte.len, std.c.MSG.DONTWAIT) == 0);
    }

    try std.testing.expectEqual(@as(usize, 1), closed);

    // Every other row has an exchange in flight: the next one is refused.
    markInFlight(connections, now(io));
    clients[Connections.capacity + 1] = try address.connect(io, .{
        .mode = .stream,
    });
    try expectAnswer(io, clients[Connections.capacity + 1].?, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    try waitForConnectionMetrics(proxy, Connections.capacity, 1);
    try std.testing.expectEqual(@as(u64, 1), proxy.metrics().evictions);
}

/// Moves every row still reading its CONNECT head to relaying with one
/// exchange in flight, as if it had authenticated.
fn markInFlight(connections: *Connections, now_ms: i64) void {
    for (0..Connections.capacity) |index| {
        if (connections.phase[index].load(.acquire) != .connect_head) {
            continue;
        }

        const slot: Connections.Slot = @enumFromInt(index);
        connections.enter(slot, .open, now_ms);
        connections.beginExchange(slot);
    }
}

fn now(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

fn waitForMetric(proxy: *const Proxy, comptime field: []const u8, expected: u64) !void {
    for (0..1000) |_| {
        if (@field(proxy.metrics(), field) == expected) {
            return;
        }

        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }

    return error.ProxyMetricNotObserved;
}

test "a CONNECT head past its bound is answered 431 and counted" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var files = try ProxyTestFiles.init(io);
    defer files.deinit();
    const proxy = try Proxy.create(io, gpa, files.config());
    defer proxy.destroy();

    const client = try proxy.address().connect(io, .{
        .mode = .stream,
    });
    defer client.close(io);
    var write_buffer: [1024]u8 = undefined;
    var writer = client.writer(io, &write_buffer);
    // Exactly the bound and nothing past it, so no unread byte turns the
    // proxy's close into a reset before the answer is read.
    const start = "CONNECT example.test:443 HTTP/1.1\r\nX-Pad: ";
    try writer.interface.writeAll(start);
    try writer.interface.splatByteAll('p', Tunnel.max_connect_head_bytes - start.len);
    try writer.interface.flush();

    try expectAnswer(io, client, "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    try std.testing.expectEqual(@as(u64, 1), proxy.metrics().connect_heads_too_large);
}

fn expectAnswer(io: std.Io, stream: std.Io.net.Stream, comptime expected: []const u8) !void {
    var read_buffer: [256]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var answer: [expected.len]u8 = undefined;
    try reader.interface.readSliceAll(&answer);
    try std.testing.expectEqualStrings(expected, &answer);
}

test {
    std.testing.refAllDecls(ca);
    _ = @import("Connections.zig");
    _ = @import("Resolutions.zig");
    _ = @import("name_resolution.zig");
    _ = @import("capture/capture_tests.zig");
    _ = @import("tunnel/tunnel_namespace.zig");
    _ = @import("tunnel/EventObserver.zig");
    _ = @import("tunnel/StreamsInFlight.zig");
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
    legacy_port: [std.fs.max_path_bytes]u8 = undefined,
    legacy_port_len: usize = 0,

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
        files.port_len = (try std.fmt.bufPrint(&files.port, "{s}/proxy-port-test", .{directory})).len;
        files.legacy_port_len = (try std.fmt.bufPrint(&files.legacy_port, "{s}/proxy-port", .{directory})).len;

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
            .legacy_port_path = self.legacy_port[0..self.legacy_port_len],
            .endpoint = "/test/runtime.sock",
        };
    }
};
