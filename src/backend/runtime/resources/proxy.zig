//! Optional proxy ownership and observation scheduling for one runtime.

const std = @import("std");
const core = @import("telar-core");
const proxy_mod = @import("../../proxy/root.zig");

const Io = std.Io;
const schema = core.schema;

pub const Config = proxy_mod.Config;

pub const InitOptions = struct {
    config: ?Config,
    system_trusted: bool,
};

pub const ObservationScheduler = struct {
    context: *anyopaque,
    schedule_fn: *const fn (*anyopaque, *proxy_mod.Proxy) anyerror!void,

    fn schedule(scheduler: ObservationScheduler, proxy: *proxy_mod.Proxy) !void {
        return scheduler.schedule_fn(scheduler.context, proxy);
    }
};

pub const CaptureScheduler = struct {
    context: *anyopaque,
    schedule_fn: *const fn (*anyopaque, *proxy_mod.Proxy) anyerror!void,

    fn schedule(scheduler: CaptureScheduler, proxy: *proxy_mod.Proxy) !void {
        return scheduler.schedule_fn(scheduler.context, proxy);
    }
};

pub const CaptureInput = struct {
    now_ms: i64,
    half: *proxy_mod.CaptureHalf,
};

pub const CaptureSink = struct {
    context: *anyopaque,
    submit_fn: *const fn (*anyopaque, *proxy_mod.CaptureExchange) void,

    fn submit(sink: CaptureSink, exchange: *proxy_mod.CaptureExchange) void {
        sink.submit_fn(sink.context, exchange);
    }
};

fn Owner(comptime Capability: type, comptime destroyCapability: *const fn (*Capability) void) type {
    return struct {
        const Self = @This();

        capability: ?*Capability,

        fn init(capability: ?*Capability) Self {
            return .{ .capability = capability };
        }

        fn schedule(owner: *Self, scheduler: anytype) !void {
            const capability = owner.capability orelse return;
            return scheduler.schedule(capability);
        }

        fn deinit(owner: *Self) void {
            const capability = owner.capability orelse return;
            owner.capability = null;
            destroyCapability(capability);
        }
    };
}

fn destroyProxy(proxy: *proxy_mod.Proxy) void {
    proxy.destroy();
}

const ProxyOwner = Owner(proxy_mod.Proxy, destroyProxy);

pub const Runtime = struct {
    owner: ProxyOwner,
    scope: schema.ProxyScope,
    system_trusted: bool,
    captures: proxy_mod.CaptureJoiner,
    capture_sink: ?CaptureSink = null,

    /// Creates the configured proxy, or an inactive owner when disabled.
    ///
    /// ```zig
    /// var proxy_runtime = try Runtime.init(io, gpa, .{ .config = config, .system_trusted = false });
    /// defer proxy_runtime.deinit();
    /// ```
    pub fn init(io: Io, gpa: std.mem.Allocator, options: InitOptions) !Runtime {
        const owned_proxy = if (options.config) |value|
            try proxy_mod.Proxy.create(io, gpa, value)
        else
            null;

        const timeout_ms = if (options.config) |value| value.capture.join_timeout_ms else (proxy_mod.CaptureConfig{}).join_timeout_ms;

        return .{
            .owner = .init(owned_proxy),
            .scope = if (options.config) |value| configuredScope(value.intercept_hosts) else .exact,
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
    pub fn capability(runtime: *const Runtime) ?*proxy_mod.Proxy {
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
    pub fn interceptionScope(runtime: *const Runtime) schema.ProxyScope {
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
    pub fn decodeCapture(runtime: *Runtime, half: *proxy_mod.CaptureHalf) void {
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

    fn submitCapture(runtime: *Runtime, exchange: *proxy_mod.CaptureExchange) void {
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
    pub fn metrics(runtime: *const Runtime) proxy_mod.MetricsSnapshot {
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
};

fn configuredScope(hosts: []const []const u8) schema.ProxyScope {
    for (hosts) |host| {
        if (std.mem.startsWith(u8, host, "*")) {
            return .wildcard;
        }
    }

    return .exact;
}

test "runtime scope distinguishes exact and wildcard policies" {
    try std.testing.expectEqual(schema.ProxyScope.exact, configuredScope(&.{"api.openai.com"}));
    try std.testing.expectEqual(schema.ProxyScope.wildcard, configuredScope(&.{"*.openai.com"}));
    try std.testing.expectEqual(schema.ProxyScope.wildcard, configuredScope(&.{"*"}));
}

const FakeCapability = struct {
    destroy_count: usize = 0,
};

fn destroyFakeCapability(capability: *FakeCapability) void {
    capability.destroy_count += 1;
}

const FakeOwner = Owner(FakeCapability, destroyFakeCapability);

const FakeScheduler = struct {
    scheduled: usize = 0,
    failure: ?anyerror = null,

    fn schedule(scheduler: *FakeScheduler, _: *FakeCapability) !void {
        scheduler.scheduled += 1;

        if (scheduler.failure) |err| {
            return err;
        }
    }
};

const ScheduleCapture = struct {
    count: usize = 0,
    capability: ?*proxy_mod.Proxy = null,
    failure: ?anyerror = null,

    fn schedule(context: *anyopaque, capability: *proxy_mod.Proxy) !void {
        const capture: *ScheduleCapture = @ptrCast(@alignCast(context));
        capture.count += 1;
        capture.capability = capability;

        if (capture.failure) |err| {
            return err;
        }
    }

    fn scheduler(capture: *ScheduleCapture) ObservationScheduler {
        return .{ .context = capture, .schedule_fn = schedule };
    }
};

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

test "disabled owner does not schedule or destroy a capability" {
    var owner: FakeOwner = .init(null);
    var scheduler: FakeScheduler = .{};

    try owner.schedule(&scheduler);
    owner.deinit();
    owner.deinit();

    try std.testing.expectEqual(@as(usize, 0), scheduler.scheduled);
}

test "schedule failure preserves ownership and deinit destroys exactly once" {
    var capability: FakeCapability = .{};
    var owner: FakeOwner = .init(&capability);
    var scheduler: FakeScheduler = .{ .failure = error.SchedulerUnavailable };

    try std.testing.expectError(error.SchedulerUnavailable, owner.schedule(&scheduler));
    try std.testing.expect(owner.capability == &capability);
    scheduler.failure = null;
    try owner.schedule(&scheduler);
    owner.deinit();
    owner.deinit();

    try std.testing.expectEqual(@as(usize, 2), scheduler.scheduled);
    try std.testing.expectEqual(@as(usize, 1), capability.destroy_count);
}

test "disabled runtime exposes zero state and skips receive scheduling" {
    var runtime = try Runtime.init(std.testing.io, std.testing.allocator, .{ .config = null, .system_trusted = true });
    var capture: ScheduleCapture = .{};

    try runtime.schedule(capture.scheduler());
    try std.testing.expect(!runtime.active());
    try std.testing.expect(runtime.systemTrusted());
    try std.testing.expect(runtime.capability() == null);
    try std.testing.expectEqualDeep(proxy_mod.MetricsSnapshot{}, runtime.metrics());
    try std.testing.expectEqual(@as(usize, 0), capture.count);

    runtime.deinit();
    runtime.deinit();
}

test "configured runtime schedules its owned proxy and tears it down" {
    const io = std.testing.io;
    var files = try ProxyTestFiles.init(io);
    defer files.deinit();
    var runtime = try Runtime.init(io, std.testing.allocator, .{ .config = files.config(), .system_trusted = false });
    var capture: ScheduleCapture = .{ .failure = error.SchedulerUnavailable };

    try std.testing.expectError(error.SchedulerUnavailable, runtime.schedule(capture.scheduler()));
    try std.testing.expect(runtime.active());
    capture.failure = null;
    try runtime.schedule(capture.scheduler());

    try std.testing.expect(capture.capability == runtime.capability());
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqualDeep(runtime.capability().?.metrics(), runtime.metrics());

    runtime.deinit();
    runtime.deinit();
    try std.testing.expect(!runtime.active());
}
