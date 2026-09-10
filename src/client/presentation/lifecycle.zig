//! Single-flight presentation identity. Preparation never retires model damage.
const std = @import("std");
const presentation = @import("root.zig");
const panes = @import("../panes/root.zig");

pub const Token = enum(u64) { _ };
pub const Outcome = enum { delivered, failed, cancelled };
pub const Submission = struct {
    observation: presentation.Observation,
    commit: panes.PresentationCommit,
    geometry: presentation.Geometry = .{},
    media_pending: bool = false,
};

pub const State = struct {
    observed: presentation.Observation = .{},
    prepared: presentation.Observation = .{},
    delivered: presentation.Observation = .{},
    delivered_geometry: ?presentation.Geometry = null,
    preparation_invalid: bool = false,
    next_token: u64 = 1,
    active: ?Flight = null,

    const Flight = struct {
        token: Token,
        observation: presentation.Observation,
        geometry: presentation.Geometry,
        delivery: presentation.Delivery,
    };

    /// Coalesces an observation without retaining model or projection pointers.
    /// Example: `if (state.observe(observation)) requestDraw();`.
    pub fn observe(state: *State, observation: presentation.Observation) bool {
        if (std.meta.eql(state.observed, observation)) {
            return false;
        }

        state.observed = observation;
        return true;
    }

    /// Indicates new or failed work; an in-flight unchanged preparation is not new work.
    /// Example: `if (state.needsPreparation()) requestDraw();`.
    pub fn needsPreparation(state: *const State) bool {
        return state.preparation_invalid or !std.meta.eql(state.observed, state.prepared);
    }

    /// Seals owned identities after synchronous preparation. No pane data is borrowed.
    /// Example: `const token = try state.begin(.{ .observation = observed, .commit = commit });`.
    pub fn begin(state: *State, submission: Submission) !Token {
        if (state.active != null) {
            return error.PresentationBusy;
        }

        if (!std.meta.eql(submission.observation, state.observed)) {
            return error.StaleProjection;
        }

        if (state.next_token == std.math.maxInt(u64)) {
            return error.PresentationIdExhausted;
        }

        if (submission.commit.len > submission.commit.panes.len) {
            return error.InvalidPresentationCommit;
        }

        const token: Token = @enumFromInt(state.next_token);
        state.next_token += 1;
        state.prepared = submission.observation;
        state.preparation_invalid = false;
        state.active = .{
            .token = token,
            .observation = submission.observation,
            .geometry = submission.geometry,
            .delivery = .{ .commit = submission.commit, .media_pending = submission.media_pending },
        };
        return token;
    }

    /// Releases exactly one flight. Old completions cannot consume newer work.
    /// A delivered older model version still ACKs only its captured pane frames.
    /// Example: `const delivery = state.complete(token, .delivered) orelse return;`.
    pub fn complete(state: *State, token: Token, outcome: Outcome) ?presentation.Delivery {
        const flight = state.active orelse return null;
        if (flight.token != token) {
            return null;
        }

        state.active = null;
        if (outcome != .delivered) {
            state.preparation_invalid = true;
            return null;
        }

        state.delivered = flight.observation;
        state.delivered_geometry = flight.geometry;
        return flight.delivery;
    }
};

test "failed and cancelled frames remain pending; stale completions cannot retire replacements" {
    var state: State = .{};
    const observation: presentation.Observation = .{ .model = .{ .frame = 1 } };
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
    var state: State = .{};
    const old: presentation.Observation = .{ .model = .{ .frame = 1 } };
    const newer: presentation.Observation = .{ .model = .{ .frame = 2 } };
    _ = state.observe(old);
    var commit: panes.PresentationCommit = .{ .len = 1 };
    commit.panes[0] = .{ .pane_id = @enumFromInt(1), .frame_id = 7, .attached = true };
    const token = try state.begin(.{ .observation = old, .commit = commit });
    _ = state.observe(newer);
    const delivery = state.complete(token, .delivered).?;
    try std.testing.expectEqual(@as(u64, 7), delivery.commit.slice()[0].frame_id);
    try std.testing.expect(state.needsPreparation());
    try std.testing.expectEqualDeep(old, state.delivered);
    try std.testing.expectError(error.StaleProjection, state.begin(.{ .observation = old, .commit = commit }));
}
