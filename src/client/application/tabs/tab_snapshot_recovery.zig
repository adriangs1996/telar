//! Application policy for coalescing canonical tab-snapshot recovery.

const std = @import("std");
const core = @import("telar-core");

pub const schema = core.schema;

pub const Effects = @import("TabSnapshotRecoveryEffects.zig");

pub const Outcome = enum {
    coalesced,
    requested,
};

pub const RequestTabSnapshotRecoveryHandler = @import("RequestTabSnapshotRecoveryHandler.zig");

pub const Event = union(enum) {
    pending,
    request: schema.TabLocation,
};

const Capture = @import("TabSnapshotRecoveryCapture.zig");

const testing_location: schema.TabLocation = .{
    .workspace = .{ .workspace = @enumFromInt(3) },
    .tab_id = @enumFromInt(5),
};

test "RequestTabSnapshotRecoveryHandler coalesces an existing repair" {
    var capture: Capture = .{ .is_pending = true };
    var handler = capture.handler();

    try std.testing.expectEqual(Outcome.coalesced, try handler.execute(testing_location));
    try std.testing.expectEqualDeep(&[_]Event{.pending}, capture.eventSlice());
}

test "RequestTabSnapshotRecoveryHandler requests one exact canonical repair" {
    var capture: Capture = .{};
    var handler = capture.handler();

    try std.testing.expectEqual(Outcome.requested, try handler.execute(testing_location));
    try std.testing.expectEqualDeep(&[_]Event{
        .pending,
        .{ .request = testing_location },
    }, capture.eventSlice());
}

test "RequestTabSnapshotRecoveryHandler preserves a failed request" {
    var capture: Capture = .{ .request_failure = error.SnapshotRequestFailed };
    var handler = capture.handler();

    try std.testing.expectError(error.SnapshotRequestFailed, handler.execute(testing_location));
    try std.testing.expectEqualDeep(&[_]Event{
        .pending,
        .{ .request = testing_location },
    }, capture.eventSlice());
}
