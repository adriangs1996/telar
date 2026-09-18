//! Bounded, disposable disclosure state. Streaming revisions and reordered
//! rows preserve it; a replacement attachment can never inherit it.
const std = @import("std");
const Control = @import("ThreadItemControl.zig");
const Expansions = @This();

pub const capacity = 128;
items: [capacity]Control = undefined,
len: usize = 0,

/// Example: `if (expansions.contains(control)) drawDetails();`
pub fn contains(state: *const Expansions, control: Control) bool {
    for (state.items[0..state.len]) |item| {
        if (item.sameItem(control)) {
            return true;
        }
    }

    return false;
}

/// Evicts the oldest open disclosure at capacity without allocating.
/// Example: `expansions.toggle(control);`
pub fn toggle(state: *Expansions, control: Control) void {
    for (state.items[0..state.len], 0..) |item, index| {
        if (item.sameItem(control)) {
            std.mem.copyForwards(Control, state.items[index .. state.len - 1], state.items[index + 1 .. state.len]);
            state.len -= 1;
            return;
        }
    }

    if (state.len == capacity) {
        std.mem.copyForwards(Control, state.items[0 .. capacity - 1], state.items[1..]);
        state.len -= 1;
    }

    state.items[state.len] = control;
    state.len += 1;
}

test "disclosures survive item reorder and never transfer to a replacement owner" {
    var state: Expansions = .{};
    const control: Control = .{ .pane_id = @enumFromInt(1), .attachment_generation = 3, .identity = 42 };
    state.toggle(control);
    var other = control;
    other.identity = 41;
    state.toggle(other);
    try std.testing.expect(state.contains(control));
    other = control;
    other.attachment_generation += 1;
    try std.testing.expect(!state.contains(other));
    other = control;
    other.pane_id = @enumFromInt(2);
    try std.testing.expect(!state.contains(other));
    state.toggle(control);
    try std.testing.expect(!state.contains(control));
    try std.testing.expectEqual(@as(usize, 1), state.len);
}

test "disclosure retention is bounded and evicts only the oldest open item" {
    var state: Expansions = .{};
    var control: Control = .{ .pane_id = @enumFromInt(1), .attachment_generation = 1, .identity = 1 };
    for (1..capacity + 2) |identity| {
        control.identity = identity;
        state.toggle(control);
    }

    try std.testing.expectEqual(capacity, state.len);
    control.identity = 1;
    try std.testing.expect(!state.contains(control));
    control.identity = 2;
    try std.testing.expect(state.contains(control));
}

test "disclosure follows a provider fragment across live and historical numbering" {
    var state: Expansions = .{};
    const live: Control = .{ .pane_id = @enumFromInt(1), .attachment_generation = 3, .identity = 7, .source_key = 42 };
    state.toggle(live);
    var historical = live;
    historical.identity = 999;
    try std.testing.expect(state.contains(historical));
    historical.source_key = 43;
    try std.testing.expect(!state.contains(historical));
    historical = live;
    historical.attachment_generation += 1;
    try std.testing.expect(!state.contains(historical));
}
