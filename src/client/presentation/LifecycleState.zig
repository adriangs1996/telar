const State = @This();
const presentation = @import("root.zig");
const source_namespace = @import("lifecycle.zig");
const std = @import("std");
const Submission = @import("Submission.zig");
observed: presentation.Observation = .{},
prepared: presentation.Observation = .{},
delivered: presentation.Observation = .{},
delivered_geometry: ?presentation.Geometry = null,
preparation_invalid: bool = false,
next_token: u64 = 1,
active: ?Flight = null,

const Flight = struct {
    token: source_namespace.Token,
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
pub fn begin(state: *State, submission: Submission) !source_namespace.Token {
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

    const token: source_namespace.Token = @enumFromInt(state.next_token);
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
pub fn complete(state: *State, token: source_namespace.Token, outcome: source_namespace.Outcome) ?presentation.Delivery {
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
