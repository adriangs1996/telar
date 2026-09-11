const proxy_ops = @import("proxy.zig");
const ProxyScopeType = @import("telar-core").ProxyScope;
const Joiner = @import("../../proxy/capture/Joiner.zig");
const CaptureSink = @import("CaptureSink.zig");
const std = @import("std");
const InitOptions = @import("InitOptions.zig");
const ProxyType = @import("../../proxy/Proxy.zig");
const Config = @import("../../proxy/capture/Config.zig");
const ObservationScheduler = @import("ObservationScheduler.zig");
const CaptureScheduler = @import("CaptureScheduler.zig");
const CaptureInput = @import("CaptureInput.zig");
const Half = @import("../../proxy/capture/Half.zig");
const Exchange = @import("../../proxy/capture/Exchange.zig");
const Snapshot = @import("../../proxy/Snapshot.zig");
const Runtime = @This();

owner: proxy_ops.ProxyOwner,
scope: ProxyScopeType,
system_trusted: bool,
captures: Joiner,
capture_sink: ?CaptureSink = null,

/// Creates the configured proxy, or an inactive owner when disabled.
///
/// ```zig
/// var proxy_runtime = try Runtime.init(io, gpa, .{ .config = config, .system_trusted = false });
/// defer proxy_runtime.deinit();
/// ```
pub fn init(io: std.Io, gpa: std.mem.Allocator, options: InitOptions) !Runtime {
    const owned_proxy = if (options.config) |value|
        try ProxyType.create(io, gpa, value)
    else
        null;

    const timeout_ms = if (options.config) |value| value.capture.join_timeout_ms else (Config{}).join_timeout_ms;

    return .{
        .owner = .init(owned_proxy),
        .scope = if (options.config) |value| proxy_ops.configuredScope(value.intercept_hosts) else .exact,
        .system_trusted = options.system_trusted,
        .captures = .init(timeout_ms),
        .capture_sink = null,
    };
}

/// Borrows the proxy capability while this owner remains active.
///
/// ```zig
/// const proxy = proxy_runtime.capability();
/// ```
pub fn capability(runtime: *const Runtime) ?*ProxyType {
    return runtime.owner.capability;
}

/// Reports whether this runtime owns an active proxy capability.
///
/// ```zig
/// if (proxy_runtime.active()) { ... }
/// ```
pub fn active(runtime: *const Runtime) bool {
    return runtime.owner.capability != null;
}

/// Reports whether active interception includes wildcard host rules.
///
/// ```zig
/// if (proxy_runtime.interceptionScope() == .wildcard) warnExpandedScope();
/// ```
pub fn interceptionScope(runtime: *const Runtime) ProxyScopeType {
    return runtime.scope;
}

/// Reports whether Telar's short-lived authority is installed in the
/// platform trust store, independently of whether the proxy is active.
///
/// ```zig
/// if (proxy_runtime.systemTrusted()) warnPersistentTrust();
/// ```
pub fn systemTrusted(runtime: *const Runtime) bool {
    return runtime.system_trusted;
}

/// Schedules one observation receive when the proxy is active.
/// Disabled runtimes treat scheduling as a successful no-op.
///
/// ```zig
/// try proxy_runtime.schedule(scheduler);
/// ```
pub fn schedule(runtime: *Runtime, scheduler: ObservationScheduler) !void {
    return runtime.owner.schedule(scheduler);
}

/// Arms one runtime receive operation when the proxy is active.
///
/// ```zig
/// try runtime.scheduleCapture(scheduler);
/// ```
pub fn scheduleCapture(runtime: *Runtime, scheduler: CaptureScheduler) !void {
    return runtime.owner.schedule(scheduler);
}

/// Adds a half to the join table and releases completed exchange data.
///
/// ```zig
/// runtime.acceptCapture(.{ .now_ms = now_ms, .half = half });
/// ```
pub fn acceptCapture(runtime: *Runtime, input: CaptureInput) void {
    runtime.expireCaptures(input.now_ms);

    switch (runtime.captures.push(input.now_ms, input.half)) {
        .pending => {},
        .complete => |value| {
            var exchange = value;
            runtime.submitCapture(&exchange);
        },
        .partial => |value| {
            var exchange = value;
            exchange.deinit();
        },
    }
}

/// Delegates bounded content decoding to the active proxy service.
///
/// ```zig
/// runtime.decodeCapture(half);
/// ```
pub fn decodeCapture(runtime: *Runtime, half: *Half) void {
    const proxy = runtime.owner.capability orelse return;
    proxy.decodeCapture(half);
}

/// Releases every partial capture whose join deadline has elapsed.
///
/// ```zig
/// runtime.expireCaptures(now_ms);
/// ```
pub fn expireCaptures(runtime: *Runtime, now_ms: i64) void {
    while (runtime.captures.expire(now_ms)) |value| {
        var exchange = value;
        runtime.submitCapture(&exchange);
    }
}

pub fn setCaptureSink(runtime: *Runtime, sink: CaptureSink) void {
    runtime.capture_sink = sink;
}

fn submitCapture(runtime: *Runtime, exchange: *Exchange) void {
    if (runtime.capture_sink) |sink| {
        sink.submit(exchange);
        return;
    }

    exchange.deinit();
}

/// Returns active proxy metrics or an all-zero inactive snapshot.
///
/// ```zig
/// const metrics = proxy_runtime.metrics();
/// ```
pub fn metrics(runtime: *const Runtime) Snapshot {
    const owned_proxy = runtime.owner.capability orelse return .{};
    return owned_proxy.metrics();
}

/// Destroys the proxy at most once. Outstanding receives must already be
/// canceled by the runtime's event scheduler.
///
/// ```zig
/// select.cancelDiscard();
/// proxy_runtime.deinit();
/// ```
pub fn deinit(runtime: *Runtime) void {
    runtime.captures.deinit();
    runtime.owner.deinit();
}
