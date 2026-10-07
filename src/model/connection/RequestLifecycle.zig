const Tracker = @import("Tracker.zig");
const core = @import("telar-core");
const std = @import("std");
const RequestLifecycle = @This();

next_request_id: u64 = 2,
tracker: Tracker = .{},

/// Checks that one request slot and `id_count` consecutive identities
/// remain without changing either resource.
///
/// ```zig
/// try self.ensureCanStart(2);
/// ```
pub fn ensureCanStart(self: *const RequestLifecycle, id_count: u64) !void {
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
pub fn nextId(self: *RequestLifecycle) !core.RequestId {
    try self.ensureCanStart(1);

    const request_id: core.RequestId = @enumFromInt(self.next_request_id);
    self.next_request_id += 1;

    return request_id;
}
