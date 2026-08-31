//! Vertical contract tests for runtime-stop authority and notification.

const std = @import("std");
const runtime_stop_commands = @import("../application/commands/runtime_stop.zig");
const runtime_stop_controller = @import("../entrypoints/requests/runtime_stop.zig");
const delivery_mod = @import("../delivery/root.zig");
const shutdown_mod = @import("../lifecycle/root.zig").shutdown_authority;

const Recipient = struct {
    active: bool,
    delivery: *delivery_mod.Delivery,
};

const Broadcaster = struct {
    recipients: [3]*Recipient,
    calls: usize = 0,
    event: ?shutdown_mod.StopRequested = null,

    fn notifications(broadcaster: *Broadcaster) runtime_stop_commands.Notifications {
        return .{ .context = broadcaster, .publish_fn = publish };
    }

    fn publish(context: *anyopaque, event: shutdown_mod.StopRequested) void {
        const broadcaster: *Broadcaster = @ptrCast(@alignCast(context));
        broadcaster.calls += 1;
        broadcaster.event = event;

        for (broadcaster.recipients) |recipient| {
            if (recipient.active) {
                recipient.delivery.requestStop();
            }
        }
    }
};

test "the first runtime-stop request notifies every active recipient once" {
    const gpa = std.testing.allocator;
    var first_delivery = try delivery_mod.Delivery.init(gpa);
    defer first_delivery.deinit(gpa);
    var inactive_delivery = try delivery_mod.Delivery.init(gpa);
    defer inactive_delivery.deinit(gpa);
    var third_delivery = try delivery_mod.Delivery.init(gpa);
    defer third_delivery.deinit(gpa);
    var shutdown: shutdown_mod.State = .{};
    var first: Recipient = .{ .active = true, .delivery = &first_delivery };
    var inactive: Recipient = .{ .active = false, .delivery = &inactive_delivery };
    var third: Recipient = .{ .active = true, .delivery = &third_delivery };
    var broadcaster: Broadcaster = .{ .recipients = .{ &first, &inactive, &third } };
    var handler: runtime_stop_commands.RuntimeStopHandler = .{
        .shutdown = &shutdown,
        .notifications = broadcaster.notifications(),
    };
    var controller = runtime_stop_controller.Controller.init(handler.executor());
    const initiator: shutdown_mod.ClientKey = .{ .id = 17, .generation = 23 };

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
