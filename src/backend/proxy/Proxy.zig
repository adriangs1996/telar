const exchangecapture = @import("exchangecapture");
const owned = @import("capture/owned.zig");
const std = @import("std");
const proxy_namespace = @import("proxy_namespace.zig");
const Config = @import("Config.zig");
const Service = @import("service/Service.zig");
const Half = owned.Half;
const PaneEnvironmentOptions = @import("PaneEnvironmentOptions.zig");
const PaneEnvironment = @import("PaneEnvironment.zig");
const pty = @import("pty");
const Override = pty.Override;
const ChildEnvironment = pty.ChildEnvironment;
const Snapshot = @import("Snapshot.zig");
const Proxy = @This();

gpa: std.mem.Allocator,
service: *Service,

/// Creates and starts the complete proxy capability.
///
/// ```zig
/// const proxy = try Proxy.create(io, gpa, config);
/// defer proxy.destroy();
/// ```
pub fn create(io: std.Io, gpa: std.mem.Allocator, config: Config) !*Proxy {
    const proxy = try gpa.create(Proxy);
    errdefer gpa.destroy(proxy);

    const service = try Service.create(io, gpa, .{
        .key = config.key_path,
        .certificate = config.certificate_path,
        .bundle = config.bundle_path,
        .secret = config.secret_path,
        .port = config.port_path,
        .legacy_port = config.legacy_port_path,
        .endpoint = config.endpoint,
        .system_authority = config.system_authority,
        .intercept_hosts = config.intercept_hosts,
        .capture = config.capture,
    });

    errdefer service.destroy();
    try service.start();
    proxy.* = .{
        .gpa = gpa,
        .service = service,
    };

    return proxy;
}

/// Cancels proxy traffic, closes capture delivery, and releases the
/// capability. The caller must first cancel its outstanding `receiveCapture`
/// operations.
///
/// ```zig
/// proxy.destroy();
/// ```
pub fn destroy(self: *Proxy) void {
    const gpa = self.gpa;
    self.service.stop();
    self.service.destroy();
    gpa.destroy(self);
}

/// Waits for one heap-owned captured exchange half, its body decoded when
/// `decode` asks, off the event loop.
///
/// ```zig
/// const half = try proxy.receiveCapture(io, tap_listens);
/// ```
pub fn receiveCapture(self: *Proxy, io: std.Io, decode: bool) anyerror!*Half {
    return self.service.receiveCapture(io, decode);
}

/// Returns the owned child environment of a new pane. `pane_overrides`
/// carries the pane's identity variables; the proxy adds the shared proxy
/// URL and trust configuration after them.
///
/// ```zig
/// var pane_environment = try proxy.environment(.{ .inherited = inherited, .overrides = pane_overrides });
/// defer pane_environment.deinit();
/// ```
pub fn environment(self: *Proxy, options: PaneEnvironmentOptions) !PaneEnvironment {
    std.debug.assert(options.overrides.len <= proxy_namespace.max_pane_overrides);
    const service = self.service;
    var url_buffer: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &url_buffer);
    const proxy_url = try service.proxyUrl(&url_buffer);
    const client = service.clientConfiguration();
    const proxy_overrides = proxy_namespace.environmentOverrides(
        proxy_url,
        client.certificate_path,
        client.bundle_path,
    );
    var overrides: [proxy_namespace.max_pane_overrides + proxy_namespace.environment_override_count]Override = undefined;
    @memcpy(overrides[0..options.overrides.len], options.overrides);
    @memcpy(overrides[options.overrides.len .. options.overrides.len + proxy_overrides.len], &proxy_overrides);
    return .{ .value = try ChildEnvironment.initWithOverrides(self.gpa, options.inherited, .{
        .telar_term_program = "telar",
        .overrides = overrides[0 .. options.overrides.len + proxy_overrides.len],
    }) };
}

/// Returns a lock-free snapshot of proxy counters.
///
/// ```zig
/// const snapshot = proxy.metrics();
/// ```
pub fn metrics(self: *const Proxy) Snapshot {
    return self.service.metrics();
}

/// Returns the capture bounds the proxy was started with.
///
/// ```zig
/// const bounds = proxy.captureConfig();
/// ```
pub fn captureConfig(self: *const Proxy) exchangecapture.Config {
    return self.service.captures.config;
}

pub fn address(self: *const Proxy) std.Io.net.IpAddress {
    const client = self.service.clientConfiguration();

    return std.Io.net.IpAddress.parse("127.0.0.1", client.port) catch unreachable;
}

/// Returns the loopback port children of this runtime reach the proxy on.
///
/// ```zig
/// const bound = proxy.port();
/// ```
pub fn port(self: *const Proxy) u16 {
    return self.service.clientConfiguration().port;
}

/// Returns the port this runtime tried first at start, or null when it
/// remembered none. When it differs from `port`, another process held it
/// and children that inherited it no longer reach this proxy.
///
/// ```zig
/// const displaced = proxy.preferredPort() != null and proxy.preferredPort().? != proxy.port();
/// ```
pub fn preferredPort(self: *const Proxy) ?u16 {
    return self.service.preferred_port;
}
