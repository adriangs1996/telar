const exchangecapture = @import("exchangecapture");
const owned = @import("../../proxy/capture/owned.zig");
const core = @import("telar-core");
const std = @import("std");
const Joiner = owned.Joiner;
const InitOptions = @import("InitOptions.zig");
const Proxy = @import("../../proxy/Proxy.zig");
const Config = exchangecapture.Config;
const Half = owned.Half;
const Snapshot = @import("../../proxy/Snapshot.zig");
const PluginsService = @import("../../plugins/Service.zig");
const ProxyTestFiles = @import("ProxyTestFiles.zig");
const TapLimitCounts = @import("../../plugins/TapLimitCounts.zig");
/// The runtime's optional observation proxy and the join table that pairs
/// the captured halves of each exchange.
const ProxyRuntime = @This();

/// Null while the proxy is disabled, and again after `deinit`.
proxy: ?*Proxy,
scope: core.ProxyScope,
system_trusted: bool,
captures: Joiner,
/// The proxy's counters when its limits were last reported.
reported: Snapshot = .{},
/// The tap's counters when its limits were last reported.
tap_reported: TapLimitCounts = .{},

/// Creates the configured proxy, or an inactive runtime when disabled.
///
/// ```zig
/// var proxy_runtime = try ProxyRuntime.init(io, gpa, .{ .config = config, .system_trusted = false });
/// defer proxy_runtime.deinit();
/// ```
pub fn init(io: std.Io, gpa: std.mem.Allocator, options: InitOptions) !ProxyRuntime {
    const owned_proxy = if (options.config) |value|
        try Proxy.create(io, gpa, value)
    else
        null;

    const timeout_ms = if (options.config) |value| value.capture.join_timeout_ms else (Config{}).join_timeout_ms;

    return .{
        .proxy = owned_proxy,
        .scope = if (options.config) |value| configuredScope(value.intercept_hosts) else .exact,
        .system_trusted = options.system_trusted,
        .captures = .init(timeout_ms),
    };
}

/// Borrows the proxy while it is active.
///
/// ```zig
/// const proxy = proxy_runtime.capability() orelse return;
/// ```
pub fn capability(self: *const ProxyRuntime) ?*Proxy {
    return self.proxy;
}

/// Reports whether this runtime owns an active proxy.
///
/// ```zig
/// if (proxy_runtime.active()) { ... }
/// ```
pub fn active(self: *const ProxyRuntime) bool {
    return self.proxy != null;
}

/// Reports whether active interception includes wildcard host rules.
///
/// ```zig
/// if (proxy_runtime.interceptionScope() == .wildcard) warnExpandedScope();
/// ```
pub fn interceptionScope(self: *const ProxyRuntime) core.ProxyScope {
    return self.scope;
}

/// Reports whether Telar's short-lived authority is installed in the
/// platform trust store, independently of whether the proxy is active.
///
/// ```zig
/// if (proxy_runtime.systemTrusted()) warnPersistentTrust();
/// ```
pub fn systemTrusted(self: *const ProxyRuntime) bool {
    return self.system_trusted;
}

/// Returns the port the active proxy listens on, or null while disabled.
///
/// ```zig
/// const port = proxy_runtime.port() orelse return;
/// ```
pub fn port(self: *const ProxyRuntime) ?u16 {
    const proxy = self.proxy orelse return null;
    return proxy.port();
}

/// Returns the port the active proxy tried first, or null while disabled or
/// when it remembered none.
///
/// ```zig
/// const preferred = proxy_runtime.preferredPort();
/// ```
pub fn preferredPort(self: *const ProxyRuntime) ?u16 {
    const proxy = self.proxy orelse return null;
    return proxy.preferredPort();
}

/// Joins one captured half and submits every completed or expired exchange
/// to the plugin tap. A half the join table cannot hold goes to the tap
/// alone, as a partial exchange; the result says whether the table was
/// full, so the caller reports `proxy.capture.joiner_capacity`.
///
/// ```zig
/// const joined = proxy_runtime.acceptCapture(now_ms, half, plugins);
/// ```
pub fn acceptCapture(self: *ProxyRuntime, now_ms: i64, half: *Half, tap: *PluginsService) CaptureJoin {
    self.expireCaptures(now_ms, tap);

    switch (self.captures.push(now_ms, half)) {
        .pending => return .joined,
        .complete, .partial => |value| {
            var exchange = value;
            tap.submit(&exchange);
            return .joined;
        },
        .full => |value| {
            var exchange = value;
            tap.submit(&exchange);
            return .table_full;
        },
    }
}

/// Whether a captured half found room in the join table.
pub const CaptureJoin = enum {
    joined,
    /// Every slot waited for a peer; the half went to the tap alone.
    table_full,
};

/// Returns the active proxy's capture bounds, or the defaults while
/// disabled.
///
/// ```zig
/// const bounds = proxy_runtime.captureConfig();
/// ```
pub fn captureConfig(self: *const ProxyRuntime) Config {
    const proxy = self.proxy orelse return .{};
    return proxy.captureConfig();
}

/// Submits every partial capture whose join deadline has elapsed.
///
/// ```zig
/// proxy_runtime.expireCaptures(now_ms, plugins);
/// ```
pub fn expireCaptures(self: *ProxyRuntime, now_ms: i64, tap: *PluginsService) void {
    while (self.captures.expire(now_ms)) |value| {
        var exchange = value;
        tap.submit(&exchange);
    }
}

/// Returns active proxy metrics or an all-zero inactive snapshot.
///
/// ```zig
/// const metrics = proxy_runtime.metrics();
/// ```
pub fn metrics(self: *const ProxyRuntime) Snapshot {
    const proxy = self.proxy orelse return .{};
    return proxy.metrics();
}

/// Destroys the proxy at most once. Outstanding receives must already be
/// canceled by the runtime's event loop.
///
/// ```zig
/// loop.cancel();
/// proxy_runtime.deinit();
/// ```
pub fn deinit(self: *ProxyRuntime) void {
    self.captures.deinit();
    const proxy = self.proxy orelse return;
    self.proxy = null;
    proxy.destroy();
}

fn configuredScope(hosts: []const []const u8) core.ProxyScope {
    for (hosts) |host| {
        if (std.mem.startsWith(u8, host, "*")) {
            return .wildcard;
        }
    }

    return .exact;
}

test "runtime scope distinguishes exact and wildcard policies" {
    try std.testing.expectEqual(core.ProxyScope.exact, configuredScope(&.{"api.openai.com"}));
    try std.testing.expectEqual(core.ProxyScope.wildcard, configuredScope(&.{"*.openai.com"}));
    try std.testing.expectEqual(core.ProxyScope.wildcard, configuredScope(&.{"*"}));
}

test "a disabled proxy runtime exposes zero state and tears down twice" {
    var runtime = try ProxyRuntime.init(std.testing.io, std.testing.allocator, .{ .config = null, .system_trusted = true });

    try std.testing.expect(!runtime.active());
    try std.testing.expect(runtime.systemTrusted());
    try std.testing.expect(runtime.capability() == null);
    try std.testing.expect(runtime.port() == null);
    try std.testing.expect(runtime.preferredPort() == null);
    try std.testing.expectEqualDeep(Snapshot{}, runtime.metrics());

    runtime.deinit();
    runtime.deinit();
}

test "a configured proxy runtime owns its proxy and destroys it exactly once" {
    const io = std.testing.io;
    var files = try ProxyTestFiles.init(io);
    defer files.deinit();
    var runtime = try ProxyRuntime.init(io, std.testing.allocator, .{ .config = files.config(), .system_trusted = false });

    try std.testing.expect(runtime.active());
    try std.testing.expectEqual(runtime.capability().?.port(), runtime.port().?);
    try std.testing.expect(runtime.preferredPort() == null);
    try std.testing.expectEqualDeep(runtime.capability().?.metrics(), runtime.metrics());

    runtime.deinit();
    runtime.deinit();
    try std.testing.expect(!runtime.active());
}
