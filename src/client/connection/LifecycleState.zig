const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const State = @This();

next_request_id: u64 = 2,
tracker: data.Tracker = .{},

/// Checks that one request slot and `id_count` consecutive identities
/// remain without changing either resource.
///
/// ```zig
/// try self.ensureCanStart(2);
/// ```
pub fn ensureCanStart(self: *const State, id_count: u64) !void {
    std.debug.assert(id_count != 0);
    if (!self.tracker.hasCapacity()) {
        return error.TooManyPendingRequests;
    }

    if (self.next_request_id == 0 or id_count > std.math.maxInt(u64) - self.next_request_id) {
        return error.RequestIdExhausted;
    }
}

/// Allocates one nonzero identity after checking correlation capacity.
///
/// ```zig
/// const request_id = try self.nextId();
/// ```
pub fn nextId(self: *State) !core.RequestId {
    try self.ensureCanStart(1);

    const request_id: core.RequestId = @enumFromInt(self.next_request_id);
    self.next_request_id += 1;

    return request_id;
}

test "request identities never reach the reserved zero or maximum values" {
    var state: State = .{};
    try std.testing.expectEqual(@as(core.RequestId, @enumFromInt(2)), try state.nextId());

    state.next_request_id = std.math.maxInt(u64) - 1;
    try std.testing.expectEqual(
        @as(core.RequestId, @enumFromInt(std.math.maxInt(u64) - 1)),
        try state.nextId(),
    );
    try std.testing.expectError(error.RequestIdExhausted, state.nextId());

    state.next_request_id = 0;
    try std.testing.expectError(error.RequestIdExhausted, state.nextId());
}

test "request preflight preserves identities needed by synchronous recovery" {
    var state: State = .{
        .next_request_id = std.math.maxInt(u64) - 1,
    };

    try state.ensureCanStart(1);
    try std.testing.expectError(error.RequestIdExhausted, state.ensureCanStart(2));
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, state.next_request_id);
}

test "request identity allocation stops before correlation overflow" {
    var state: State = .{};
    for (0..data.Tracker.capacity) |index| {
        try state.tracker.add(@enumFromInt(index + 20), .notification);
    }
    const next_request_id = state.next_request_id;

    try std.testing.expectError(error.TooManyPendingRequests, state.nextId());
    try std.testing.expectEqual(next_request_id, state.next_request_id);
}
