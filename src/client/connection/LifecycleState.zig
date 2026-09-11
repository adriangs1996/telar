const TrackerType = @import("Tracker.zig");
const std = @import("std");
const RequestIdType = @import("telar-core").RequestId;
const State = @This();

next_request_id: u64 = 2,
tracker: TrackerType = .{},

/// Checks that one request slot and `id_count` consecutive identities
/// remain without changing either resource.
///
/// ```zig
/// try state.ensureCanStart(2);
/// ```
pub fn ensureCanStart(state: *const State, id_count: u64) !void {
    std.debug.assert(id_count != 0);
    if (!state.tracker.hasCapacity()) {
        return error.TooManyPendingRequests;
    }
    if (state.next_request_id == 0 or id_count > std.math.maxInt(u64) - state.next_request_id) {
        return error.RequestIdExhausted;
    }
}

/// Allocates one nonzero identity after checking correlation capacity.
///
/// ```zig
/// const request_id = try state.nextId();
/// ```
pub fn nextId(state: *State) !RequestIdType {
    try state.ensureCanStart(1);

    const request_id: RequestIdType = @enumFromInt(state.next_request_id);
    state.next_request_id += 1;

    return request_id;
}
