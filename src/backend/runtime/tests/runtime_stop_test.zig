//! Vertical contract tests for runtime-stop authority and notification.

const std = @import("std");
const DeliveryType = @import("../delivery/Delivery.zig");
const StateType = @import("../lifecycle/State.zig");
const Recipient = @import("Recipient.zig");
const RuntimeStopTestBroadcaster = @import("RuntimeStopTestBroadcaster.zig");
const RuntimeStopHandlerType = @import("../application/commands/RuntimeStopHandler.zig");
const RuntimeStopController = @import("../entrypoints/requests/RuntimeStopController.zig");
const ClientKeyType = @import("../../history/ClientKey.zig");

test "the first runtime-stop request notifies every active recipient once" {
    const gpa = std.testing.allocator;
    var first_delivery = try DeliveryType.init(gpa);
    defer first_delivery.deinit(gpa);
    var inactive_delivery = try DeliveryType.init(gpa);
    defer inactive_delivery.deinit(gpa);
    var third_delivery = try DeliveryType.init(gpa);
    defer third_delivery.deinit(gpa);
    var shutdown: StateType = .{};
    var first: Recipient = .{ .active = true, .delivery = &first_delivery };
    var inactive: Recipient = .{ .active = false, .delivery = &inactive_delivery };
    var third: Recipient = .{ .active = true, .delivery = &third_delivery };
    var broadcaster: RuntimeStopTestBroadcaster = .{ .recipients = .{ &first, &inactive, &third } };
    var handler: RuntimeStopHandlerType = .{
        .shutdown = &shutdown,
        .notifications = broadcaster.notifications(),
    };
    var controller = RuntimeStopController.init(handler.executor());
    const initiator: ClientKeyType = .{ .id = 17, .generation = 23 };

    controller.runtimeStop(initiator);
    controller.runtimeStop(.{ .id = 99, .generation = 100 });

    try std.testing.expect(shutdown.isRequested());
    try std.testing.expectEqualDeep(initiator, shutdown.initiator.?);
    try std.testing.expectEqual(@as(usize, 1), broadcaster.calls);
    try std.testing.expectEqualDeep(initiator, broadcaster.event.?.initiator);
    try std.testing.expect(first_delivery.stopping());
    try std.testing.expect(!inactive_delivery.stopping());
    try std.testing.expect(third_delivery.stopping());
}
