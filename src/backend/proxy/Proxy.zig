const std = @import("std");
const proxy_namespace = @import("proxy_namespace.zig");
const Config = @import("Config.zig");
const ServiceType = @import("service/Service.zig");
const HalfType = @import("capture/Half.zig");
const PaneKeyType = @import("../pane/PaneKey.zig");
const PaneEnvironmentOptions = @import("PaneEnvironmentOptions.zig");
const PaneEnvironment = @import("PaneEnvironment.zig");
const OverrideType = @import("../pty/Override.zig");
const ChildEnvironmentType = @import("../pty/ChildEnvironment.zig");
const Observation = @import("Observation.zig");
const Snapshot = @import("Snapshot.zig");
const Proxy = @This();

gpa: std.mem.Allocator,
lifecycle: proxy_namespace.ServiceLifecycle,

/// Creates and starts the complete proxy capability.
///
/// ```zig
/// const proxy = try Proxy.create(io, gpa, config);
/// defer proxy.destroy();
/// ```
pub fn create(io: std.Io, gpa: std.mem.Allocator, config: Config) !*Proxy {
    const proxy = try gpa.create(Proxy);
    errdefer gpa.destroy(proxy);

    const service = try ServiceType.create(io, gpa, .{
        .key = config.key_path,
        .certificate = config.certificate_path,
        .bundle = config.bundle_path,
        .system_authority = config.system_authority,
        .intercept_hosts = config.intercept_hosts,
        .capture = config.capture,
    });

    proxy.* = .{
        .gpa = gpa,
        .lifecycle = try proxy_namespace.ServiceLifecycle.start(service),
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

/// Waits for one live, heap-owned captured exchange half.
///
/// ```zig
/// const half = try proxy.receiveCapture(io);
/// ```
pub fn receiveCapture(proxy: *Proxy, io: std.Io) anyerror!*HalfType {
    return proxy.lifecycle.service.receiveCapture(io);
}

/// Decodes one captured body on the runtime observation path.
///
/// ```zig
/// proxy.decodeCapture(half);
/// ```
pub fn decodeCapture(proxy: *Proxy, half: *HalfType) void {
    proxy.lifecycle.service.decodeCapture(half);
}

/// Registers one pane generation and returns its owned child environment.
/// `pane_overrides` carries the pane's identity variables; the proxy adds
/// its own credentials and trust configuration after them.
///
/// ```zig
/// var pane_environment = try proxy.registerPane(key, .{ .inherited = inherited, .overrides = pane_overrides });
/// defer pane_environment.deinit();
/// ```
pub fn registerPane(proxy: *Proxy, key: PaneKeyType, options: PaneEnvironmentOptions) !PaneEnvironment {
    std.debug.assert(options.overrides.len <= proxy_namespace.max_pane_overrides);
    const service = proxy.lifecycle.service;
    var credential = try service.registerPane(.{ .id = key.id, .generation = key.generation });
    defer std.crypto.secureZero(u8, &credential.token);
    errdefer service.unregisterCredential(&credential);

    var url_buffer: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &url_buffer);
    const proxy_url = try service.credentialUrl(&url_buffer, &credential);
    const client = service.clientConfiguration();
    const proxy_overrides = proxy_namespace.environmentOverrides(
        proxy_url,
        client.certificate_path,
        client.bundle_path,
    );
    var overrides: [proxy_namespace.max_pane_overrides + proxy_namespace.environment_override_count]OverrideType = undefined;
    @memcpy(overrides[0..options.overrides.len], options.overrides);
    @memcpy(overrides[options.overrides.len .. options.overrides.len + proxy_overrides.len], &proxy_overrides);
    return .{ .value = try ChildEnvironmentType.initWithOverrides(proxy.gpa, options.inherited, .{
        .telar_term_program = "telar",
        .overrides = overrides[0 .. options.overrides.len + proxy_overrides.len],
    }) };
}

/// Revokes new tunnels and observations for one exact pane generation.
///
/// ```zig
/// proxy.revokePane(key);
/// ```
pub fn revokePane(proxy: *Proxy, key: PaneKeyType) void {
    proxy.lifecycle.service.unregisterPane(.{ .id = key.id, .generation = key.generation });
}

/// Revocation rejects new tunnels and filters both queued and subsequent
/// observations. A tunnel already authenticated keeps forwarding bytes.
///
/// ```zig
/// const observation = try proxy.receive(io);
/// ```
pub fn receive(proxy: *Proxy, io: std.Io) anyerror!Observation {
    var event = try proxy.lifecycle.service.receive(io);
    defer std.crypto.secureZero(u8, &event.credential.token);
    return .{
        .pane = .{
            .id = event.credential.pane_id,
            .generation = event.credential.pane_generation,
        },
        .dialect = event.dialect,
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
pub fn metrics(proxy: *const Proxy) Snapshot {
    return proxy.lifecycle.service.metrics();
}

pub fn address(proxy: *const Proxy) std.Io.net.IpAddress {
    const client = proxy.lifecycle.service.clientConfiguration();

    return std.Io.net.IpAddress.parse("127.0.0.1", client.port) catch unreachable;
}
