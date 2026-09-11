//! Optional proxy ownership and observation scheduling for one runtime.

const ProxyType = @import("../../proxy/Proxy.zig");
const GenericOwner = @import("GenericOwner.zig").Type;
const ProxyScopeType = @import("telar-core").ProxyScope;
const std = @import("std");
const FakeCapability = @import("FakeCapability.zig");
const FakeScheduler = @import("FakeScheduler.zig");
const ProxyRuntime = @import("ProxyRuntime.zig");
const ScheduleCapture = @import("ScheduleCapture.zig");
const Snapshot = @import("../../proxy/Snapshot.zig");
const ProxyTestFiles = @import("ProxyTestFiles.zig");

fn destroyProxy(proxy: *ProxyType) void {
    proxy.destroy();
}

pub const ProxyOwner = GenericOwner(ProxyType, destroyProxy);

pub fn configuredScope(hosts: []const []const u8) ProxyScopeType {
    for (hosts) |host| {
        if (std.mem.startsWith(u8, host, "*")) {
            return .wildcard;
        }
    }

    return .exact;
}

test "runtime scope distinguishes exact and wildcard policies" {
    try std.testing.expectEqual(ProxyScopeType.exact, configuredScope(&.{"api.openai.com"}));
    try std.testing.expectEqual(ProxyScopeType.wildcard, configuredScope(&.{"*.openai.com"}));
    try std.testing.expectEqual(ProxyScopeType.wildcard, configuredScope(&.{"*"}));
}

fn destroyFakeCapability(capability: *FakeCapability) void {
    capability.destroy_count += 1;
}

const FakeOwner = GenericOwner(FakeCapability, destroyFakeCapability);

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
    var runtime = try ProxyRuntime.init(std.testing.io, std.testing.allocator, .{ .config = null, .system_trusted = true });
    var capture: ScheduleCapture = .{};

    try runtime.schedule(capture.scheduler());
    try std.testing.expect(!runtime.active());
    try std.testing.expect(runtime.systemTrusted());
    try std.testing.expect(runtime.capability() == null);
    try std.testing.expectEqualDeep(Snapshot{}, runtime.metrics());
    try std.testing.expectEqual(@as(usize, 0), capture.count);

    runtime.deinit();
    runtime.deinit();
}

test "configured runtime schedules its owned proxy and tears it down" {
    const io = std.testing.io;
    var files = try ProxyTestFiles.init(io);
    defer files.deinit();
    var runtime = try ProxyRuntime.init(io, std.testing.allocator, .{ .config = files.config(), .system_trusted = false });
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
