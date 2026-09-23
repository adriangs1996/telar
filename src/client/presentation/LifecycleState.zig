const Observation = @import("Observation.zig");
const Geometry = @import("Geometry.zig");
const std = @import("std");
const Submission = @import("Submission.zig");
const lifecycle = @import("lifecycle.zig");
const PresentationDelivery = @import("PresentationDelivery.zig");
const State = @This();

observed: Observation = .{},
prepared: Observation = .{},
delivered: Observation = .{},
delivered_geometry: ?Geometry = null,
preparation_invalid: bool = false,
next_token: u64 = 1,
active: ?Flight = null,

/// Coalesces an observation without retaining model or projection pointers.
/// Example: `if (state.observe(observation)) requestDraw();`.
pub fn observe(self: *State, observation: Observation) bool {
    if (std.meta.eql(self.observed, observation)) {
        return false;
    }

    self.observed = observation;
    return true;
}

/// Indicates new or failed work; an in-flight unchanged preparation is not new work.
/// Example: `if (state.needsPreparation()) requestDraw();`.
pub fn needsPreparation(self: *const State) bool {
    return self.preparation_invalid or !std.meta.eql(self.observed, self.prepared);
}

/// Seals owned identities after synchronous preparation. No pane data is borrowed.
/// Example: `const token = try state.begin(.{ .observation = observed, .commit = commit });`.
pub fn begin(self: *State, submission: Submission) !lifecycle.Token {
    if (self.active != null) {
        return error.PresentationBusy;
    }

    if (!std.meta.eql(submission.observation, self.observed)) {
        return error.StaleProjection;
    }

    if (self.next_token == std.math.maxInt(u64)) {
        return error.PresentationIdExhausted;
    }

    if (submission.commit.len > submission.commit.panes.len) {
        return error.InvalidPresentationCommit;
    }

    const token: lifecycle.Token = @enumFromInt(self.next_token);
    self.next_token += 1;
    self.prepared = submission.observation;
    self.preparation_invalid = false;
    self.active = .{
        .token = token,
        .observation = submission.observation,
        .geometry = submission.geometry,
        .delivery = .{ .commit = submission.commit, .media_pending = submission.media_pending },
    };
    return token;
}

/// Releases exactly one flight. Old completions cannot consume newer work.
/// An older successful delivery leaves subsequently received damage pending.
/// Example: `const delivery = state.complete(token, .delivered) orelse return;`.
pub fn complete(self: *State, token: lifecycle.Token, outcome: lifecycle.Outcome) ?PresentationDelivery {
    const flight = self.active orelse return null;
    if (flight.token != token) {
        return null;
    }

    self.active = null;
    if (outcome != .delivered) {
        self.preparation_invalid = true;
        return null;
    }

    self.delivered = flight.observation;
    self.delivered_geometry = flight.geometry;
    return flight.delivery;
}

const Flight = struct {
    token: lifecycle.Token,
    observation: Observation,
    geometry: Geometry,
    delivery: PresentationDelivery,
};
