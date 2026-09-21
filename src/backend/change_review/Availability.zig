const std = @import("std");
const core = @import("telar-core");
const Context = @import("Context.zig");
const Availability = @This();

context: ?Context = null,
active: bool = false,
latest_edition_id: u64 = 0,
revision: u64 = 0,
discovery_started: bool = false,

/// Rebinds discovery to the current conversation without retaining another session's edits.
/// Example: `availability.bind(context);`.
pub fn bind(self: *Availability, context: Context) void {
    if (self.active and self.matches(context)) {
        return;
    }

    self.context = context;
    self.active = true;
    self.latest_edition_id = 0;
    self.discovery_started = false;
    self.revision += 1;
}

/// Clears an owner while retaining the identity needed to invalidate client replicas.
/// Example: `availability.invalidate();`.
pub fn invalidate(self: *Availability) void {
    if (!self.active) {
        return;
    }

    self.active = false;
    self.latest_edition_id = 0;
    self.discovery_started = false;
    self.revision += 1;
}

/// Coalesces immutable edition discovery; an older worker result cannot roll it back.
/// Example: `availability.record(context, latest_edition_id);`.
pub fn record(self: *Availability, context: Context, latest_edition_id: u64) void {
    self.bind(context);
    if (latest_edition_id <= self.latest_edition_id) {
        return;
    }

    self.latest_edition_id = latest_edition_id;
    self.revision += 1;
}

pub fn view(self: *const Availability) ?core.ChangeReviewChanged {
    const context = if (self.context) |*value| value else return null;
    return .{ .pane_id = context.pane.id, .pane_generation = context.pane.generation, .session = context.sessionSlice(), .latest_edition_id = self.latest_edition_id };
}

fn matches(self: *const Availability, context: Context) bool {
    const previous = self.context orelse return false;
    return std.meta.eql(previous.pane, context.pane) and previous.provider == context.provider and std.mem.eql(u8, previous.sessionSlice(), context.sessionSlice());
}

test "review availability invalidates owner changes and coalesces late discovery" {
    var state: Availability = .{};
    const first = try Context.init(.{ .id = @enumFromInt(1), .generation = 2 }, .codex, "first");
    state.bind(first);
    state.record(first, 5);
    const revision = state.revision;
    state.record(first, 2);
    try std.testing.expectEqual(@as(u64, 5), state.latest_edition_id);
    try std.testing.expectEqual(revision, state.revision);
    var next = try Context.init(first.pane, .codex, "second");
    state.bind(next);
    try std.testing.expectEqual(@as(u64, 0), state.latest_edition_id);
    try std.testing.expectEqualStrings("second", state.view().?.session);
    state.record(next, 3);
    next.pane.generation += 1;
    state.bind(next);
    try std.testing.expectEqual(@as(u64, 0), state.latest_edition_id);
    state.record(next, 7);
    state.invalidate();
    try std.testing.expect(!state.active);
    try std.testing.expectEqual(@as(u64, 0), state.view().?.latest_edition_id);
}
