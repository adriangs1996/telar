//! Application policy for coalescing canonical tab-snapshot recovery.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const Effects = struct {
    context: *anyopaque,
    pending: *const fn (*anyopaque) bool,
    request: *const fn (*anyopaque, schema.TabLocation) anyerror!void,
};

pub const Outcome = enum {
    coalesced,
    requested,
};

pub const RequestTabSnapshotRecoveryHandler = struct {
    effects: Effects,

    /// Coalesces an existing canonical repair or requests it exactly once.
    ///
    /// ```zig
    /// const outcome = try handler.execute(location);
    /// ```
    pub fn execute(handler: *RequestTabSnapshotRecoveryHandler, location: schema.TabLocation) !Outcome {
        if (handler.effects.pending(handler.effects.context)) {
            return .coalesced;
        }

        try handler.effects.request(handler.effects.context, location);

        return .requested;
    }
};

const Event = union(enum) {
    pending,
    request: schema.TabLocation,
};

const Capture = struct {
    is_pending: bool = false,
    request_failure: ?anyerror = null,
    events: [2]Event = undefined,
    event_count: usize = 0,

    fn handler(capture: *Capture) RequestTabSnapshotRecoveryHandler {
        return .{ .effects = .{
            .context = capture,
            .pending = pending,
            .request = request,
        } };
    }

    fn pending(context: *anyopaque) bool {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.append(.pending);

        return capture.is_pending;
    }

    fn request(context: *anyopaque, location: schema.TabLocation) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.append(.{ .request = location });
        if (capture.request_failure) |failure| {
            return failure;
        }
    }

    fn append(capture: *Capture, event: Event) void {
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn eventSlice(capture: *const Capture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

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
