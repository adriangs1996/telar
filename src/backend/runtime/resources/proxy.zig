//! Optional proxy ownership and observation scheduling for one runtime.

const std = @import("std");
const core = @import("telar-core");
const proxy_mod = @import("../../proxy/root.zig");

pub const Io = std.Io;
pub const schema = core.schema;

pub const Config = proxy_mod.Config;

pub const InitOptions = @import("InitOptions.zig");

pub const ObservationScheduler = @import("ObservationScheduler.zig");

pub const CaptureScheduler = @import("CaptureScheduler.zig");

pub const CaptureInput = @import("CaptureInput.zig");

pub const CaptureSink = @import("CaptureSink.zig");

const Owner = @import("GenericOwner.zig").Type;

fn destroyProxy(proxy: *proxy_mod.Proxy) void {
    proxy.destroy();
}

pub const ProxyOwner = Owner(proxy_mod.Proxy, destroyProxy);

pub const Runtime = @import("ProxyRuntime.zig");

pub fn configuredScope(hosts: []const []const u8) schema.ProxyScope {
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

const FakeCapability = @import("FakeCapability.zig");

fn destroyFakeCapability(capability: *FakeCapability) void {
    capability.destroy_count += 1;
}

const FakeOwner = Owner(FakeCapability, destroyFakeCapability);

const FakeScheduler = @import("FakeScheduler.zig");

const ScheduleCapture = @import("ScheduleCapture.zig");

const ProxyTestFiles = @import("ProxyTestFiles.zig");

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
