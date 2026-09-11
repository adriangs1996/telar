//! Application use case for reconciling runtime TLS interception state.

const ModelType = @import("../../model/Model.zig");
const std = @import("std");
const ProxyStatusDeliveryCapture = @import("ProxyStatusDeliveryCapture.zig");
const ApplyProxyStatusHandler = @import("ApplyProxyStatusHandler.zig");
const VersionType = @import("../../model/Version.zig");

test "ApplyProxyStatusHandler commits before delivering each changed state" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: ProxyStatusDeliveryCapture = .{ .model = &model };
    var handler: ApplyProxyStatusHandler = .{
        .model = &model,
        .delivery = capture.port(),
    };

    try std.testing.expect((try handler.execute(.{ .active = false, .scope = .exact, .system_trusted = false })) == null);
    try std.testing.expectEqual(@as(usize, 0), capture.calls);

    const enabled = (try handler.execute(.{ .active = true, .scope = .wildcard, .system_trusted = false })).?;

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqualDeep(enabled, capture.commit.?);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect((try handler.execute(.{ .active = true, .scope = .wildcard, .system_trusted = false })) == null);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);

    const disabled = (try handler.execute(.{ .active = false, .scope = .exact, .system_trusted = false })).?;

    try std.testing.expect(!disabled.active);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqual(VersionType{ .proxy_status = 2 }, model.version());
}

test "ApplyProxyStatusHandler preserves a commit after delivery failure" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: ProxyStatusDeliveryCapture = .{ .model = &model, .fail = true };
    var handler: ApplyProxyStatusHandler = .{
        .model = &model,
        .delivery = capture.port(),
    };

    try std.testing.expectError(error.ProxyStatusDeliveryFailed, handler.execute(.{ .active = true, .scope = .exact, .system_trusted = false }));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expect(model.proxyTlsActive());
    try std.testing.expectEqual(VersionType{ .proxy_status = 1 }, model.version());
}
