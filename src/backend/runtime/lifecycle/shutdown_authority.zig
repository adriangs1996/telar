//! Runtime shutdown authority and its first-writer transition.

const std = @import("std");
const history_mod = @import("../../history/root.zig");

pub const ClientKey = history_mod.model.ClientKey;

pub const StopRequested = @import("StopRequested.zig");

pub const State = @import("State.zig");

test "the first shutdown requester becomes the stable authority" {
    var state: State = .{};
    const first: ClientKey = .{ .id = 7, .generation = 3 };
    const second: ClientKey = .{ .id = 8, .generation = 4 };

    try std.testing.expect(!state.isRequested());
    try std.testing.expectEqualDeep(first, state.request(first).?.initiator);
    try std.testing.expect(state.isRequested());
    try std.testing.expectEqualDeep(first, state.initiator.?);

    try std.testing.expect(state.request(first) == null);
    try std.testing.expect(state.request(second) == null);
    try std.testing.expectEqualDeep(first, state.initiator.?);
}
