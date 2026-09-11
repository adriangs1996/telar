//! Single-flight presentation identity. Preparation never retires model damage.

const LifecycleState = @import("LifecycleState.zig");
const ObservationType = @import("Observation.zig");
const std = @import("std");
const PresentationCommitType = @import("../panes/PresentationCommit.zig");

pub const Token = enum(u64) { _ };
pub const Outcome = enum { delivered, failed, cancelled };

test "failed and cancelled frames remain pending; stale completions cannot retire replacements" {
    var state: LifecycleState = .{};
    const observation: ObservationType = .{ .model = .{ .frame = 1 } };
    try std.testing.expect(state.observe(observation));
    const first = try state.begin(.{ .observation = observation, .commit = .{} });
    try std.testing.expect(!state.needsPreparation());
    try std.testing.expectError(error.PresentationBusy, state.begin(.{ .observation = observation, .commit = .{} }));
    try std.testing.expect(state.complete(first, .failed) == null);
    try std.testing.expect(state.needsPreparation());
    const second = try state.begin(.{ .observation = observation, .commit = .{} });
    try std.testing.expect(state.complete(first, .delivered) == null);
    try std.testing.expectEqual(second, state.active.?.token);
    try std.testing.expect(state.complete(second, .cancelled) == null);
    const third = try state.begin(.{ .observation = observation, .commit = .{} });
    try std.testing.expect(state.complete(third, .delivered) != null);
    try std.testing.expect(state.complete(third, .delivered) == null);
    try std.testing.expectEqualDeep(observation, state.delivered);
}

test "delivery acknowledges only captured frames even after receiving newer model state" {
    var state: LifecycleState = .{};
    const old: ObservationType = .{ .model = .{ .frame = 1 } };
    const newer: ObservationType = .{ .model = .{ .frame = 2 } };
    _ = state.observe(old);
    var commit: PresentationCommitType = .{ .len = 1 };
    commit.panes[0] = .{ .pane_id = @enumFromInt(1), .frame_id = 7, .attached = true };
    const token = try state.begin(.{ .observation = old, .commit = commit });
    _ = state.observe(newer);
    const delivery = state.complete(token, .delivered).?;
    try std.testing.expectEqual(@as(u64, 7), delivery.commit.slice()[0].frame_id);
    try std.testing.expect(state.needsPreparation());
    try std.testing.expectEqualDeep(old, state.delivered);
    try std.testing.expectError(error.StaleProjection, state.begin(.{ .observation = old, .commit = commit }));
}
