//! Application use case for reconciling runtime TLS interception state.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../root.zig").model;

pub const ProxyStatusDelivery = @import("ProxyStatusDelivery.zig");

pub const ApplyProxyStatusHandler = @import("ApplyProxyStatusHandler.zig");

const DeliveryCapture = @import("ProxyStatusDeliveryCapture.zig");

test "ApplyProxyStatusHandler commits before delivering each changed state" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: DeliveryCapture = .{ .model = &model };
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
    try std.testing.expectEqual(client_model.Version{ .proxy_status = 2 }, model.version());
}

test "ApplyProxyStatusHandler preserves a commit after delivery failure" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: DeliveryCapture = .{ .model = &model, .fail = true };
    var handler: ApplyProxyStatusHandler = .{
        .model = &model,
        .delivery = capture.port(),
    };

    try std.testing.expectError(error.ProxyStatusDeliveryFailed, handler.execute(.{ .active = true, .scope = .exact, .system_trusted = false }));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expect(model.proxyTlsActive());
    try std.testing.expectEqual(client_model.Version{ .proxy_status = 1 }, model.version());
}
