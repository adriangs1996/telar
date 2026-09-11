//! Passive in-memory storage owned by `RuntimeModel` for workspace aggregates.

const std = @import("std");
const workspace = @import("workspace_support.zig");

pub const max_workspaces = 64;

pub const State = @import("State.zig");

/// Advances projection revision while preserving zero as the unseen sentinel.
///
/// ```zig
/// advanceRevision(&state);
/// ```
pub fn advanceRevision(state: *State) void {
    state.revision +%= 1;

    if (state.revision == 0) {
        state.revision = 1;
    }
}

test "workspace state starts empty with nonzero identities and revision" {
    const state: State = .{};

    try std.testing.expectEqual(@as(usize, 0), state.count);
    try std.testing.expectEqual(@as(u64, 1), state.next_workspace_id);
    try std.testing.expectEqual(@as(u64, 1), state.next_tab_id);
    try std.testing.expectEqual(@as(u64, 1), state.revision);

    for (state.items) |slot| {
        try std.testing.expect(slot == null);
    }
}

test "workspace state revision never becomes zero" {
    var state: State = .{ .revision = std.math.maxInt(u64) };

    advanceRevision(&state);

    try std.testing.expectEqual(@as(u64, 1), state.revision);
}
