//! Application policy for coalescing canonical tab-snapshot recovery.

const TabLocationType = @import("telar-core").TabLocation;
const TabSnapshotRecoveryCapture = @import("TabSnapshotRecoveryCapture.zig");
const std = @import("std");

pub const Outcome = enum {
    coalesced,
    requested,
};

pub const Event = union(enum) {
    pending,
    request: TabLocationType,
};

const testing_location: TabLocationType = .{
    .workspace = .{ .workspace = @enumFromInt(3) },
    .tab_id = @enumFromInt(5),
};

test "RequestTabSnapshotRecoveryHandler coalesces an existing repair" {
    var capture: TabSnapshotRecoveryCapture = .{ .is_pending = true };
    var handler = capture.handler();

    try std.testing.expectEqual(Outcome.coalesced, try handler.execute(testing_location));
    try std.testing.expectEqualDeep(&[_]Event{.pending}, capture.eventSlice());
}

test "RequestTabSnapshotRecoveryHandler requests one exact canonical repair" {
    var capture: TabSnapshotRecoveryCapture = .{};
    var handler = capture.handler();

    try std.testing.expectEqual(Outcome.requested, try handler.execute(testing_location));
    try std.testing.expectEqualDeep(&[_]Event{
        .pending,
        .{ .request = testing_location },
    }, capture.eventSlice());
}

test "RequestTabSnapshotRecoveryHandler preserves a failed request" {
    var capture: TabSnapshotRecoveryCapture = .{ .request_failure = error.SnapshotRequestFailed };
    var handler = capture.handler();

    try std.testing.expectError(error.SnapshotRequestFailed, handler.execute(testing_location));
    try std.testing.expectEqualDeep(&[_]Event{
        .pending,
        .{ .request = testing_location },
    }, capture.eventSlice());
}
