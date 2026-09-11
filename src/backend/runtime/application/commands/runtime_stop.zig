//! Application command for initiating runtime shutdown exactly once.

const std = @import("std");
const shutdown_mod = @import("../../lifecycle/root.zig").shutdown_authority;

pub const RuntimeStop = @import("RuntimeStop.zig");

pub const RuntimeStopResult = enum {
    requested,
    already_requested,
};

pub const Notifications = @import("Notifications.zig");

pub const RuntimeStopExecutor = @import("RuntimeStopExecutor.zig");

pub const RuntimeStopHandler = @import("RuntimeStopHandler.zig");

const PublicationCapture = @import("RuntimeStopPublicationCapture.zig");

test "RuntimeStopHandler commits authority before publishing one event" {
    var shutdown: shutdown_mod.State = .{};
    var capture: PublicationCapture = .{ .shutdown = &shutdown };
    var handler: RuntimeStopHandler = .{
        .shutdown = &shutdown,
        .notifications = capture.notifications(),
    };
    const requester: shutdown_mod.ClientKey = .{ .id = 12, .generation = 5 };

    const result = handler.executor().execute(.{ .requester = requester });

    try std.testing.expectEqual(RuntimeStopResult.requested, result);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_committed_state);
    try std.testing.expectEqualDeep(requester, capture.event.?.initiator);
    try std.testing.expectEqualDeep(requester, shutdown.initiator.?);
}

test "RuntimeStopHandler ignores every request after the first" {
    var shutdown: shutdown_mod.State = .{};
    var capture: PublicationCapture = .{ .shutdown = &shutdown };
    var handler: RuntimeStopHandler = .{
        .shutdown = &shutdown,
        .notifications = capture.notifications(),
    };
    const first: shutdown_mod.ClientKey = .{ .id = 1, .generation = 2 };
    const second: shutdown_mod.ClientKey = .{ .id = 3, .generation = 4 };

    try std.testing.expectEqual(RuntimeStopResult.requested, handler.execute(.{ .requester = first }));
    try std.testing.expectEqual(RuntimeStopResult.already_requested, handler.execute(.{ .requester = first }));
    try std.testing.expectEqual(RuntimeStopResult.already_requested, handler.execute(.{ .requester = second }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(first, shutdown.initiator.?);
}
