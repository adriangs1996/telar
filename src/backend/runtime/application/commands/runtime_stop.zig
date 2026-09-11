//! Application command for initiating runtime shutdown exactly once.

const StateType = @import("../../lifecycle/State.zig");
const RuntimeStopPublicationCapture = @import("RuntimeStopPublicationCapture.zig");
const RuntimeStopHandler = @import("RuntimeStopHandler.zig");
const ClientKeyType = @import("../../../history/ClientKey.zig");
const std = @import("std");

pub const RuntimeStopResult = enum {
    requested,
    already_requested,
};

test "RuntimeStopHandler commits authority before publishing one event" {
    var shutdown: StateType = .{};
    var capture: RuntimeStopPublicationCapture = .{ .shutdown = &shutdown };
    var handler: RuntimeStopHandler = .{
        .shutdown = &shutdown,
        .notifications = capture.notifications(),
    };
    const requester: ClientKeyType = .{ .id = 12, .generation = 5 };

    const result = handler.executor().execute(.{ .requester = requester });

    try std.testing.expectEqual(RuntimeStopResult.requested, result);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_committed_state);
    try std.testing.expectEqualDeep(requester, capture.event.?.initiator);
    try std.testing.expectEqualDeep(requester, shutdown.initiator.?);
}

test "RuntimeStopHandler ignores every request after the first" {
    var shutdown: StateType = .{};
    var capture: RuntimeStopPublicationCapture = .{ .shutdown = &shutdown };
    var handler: RuntimeStopHandler = .{
        .shutdown = &shutdown,
        .notifications = capture.notifications(),
    };
    const first: ClientKeyType = .{ .id = 1, .generation = 2 };
    const second: ClientKeyType = .{ .id = 3, .generation = 4 };

    try std.testing.expectEqual(RuntimeStopResult.requested, handler.execute(.{ .requester = first }));
    try std.testing.expectEqual(RuntimeStopResult.already_requested, handler.execute(.{ .requester = first }));
    try std.testing.expectEqual(RuntimeStopResult.already_requested, handler.execute(.{ .requester = second }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(first, shutdown.initiator.?);
}
