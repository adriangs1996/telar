//! Observation pipeline and bounded delivery channel owned as one component.

const std = @import("std");
const identity = @import("../identity.zig");
const middleware = @import("../middleware.zig");
const observation_queue = @import("../observation_queue.zig");

const Io = std.Io;

pub const Liveness = struct {
    context: *anyopaque,
    is_live: *const fn (*anyopaque, *const identity.Credential) bool,
};

pub const Observations = struct {
    pipeline_value: middleware.Pipeline,
    channel: observation_queue.Channel,

    /// Wires one bounded channel into a fresh publication pipeline. The
    /// component must already be at its final address because the pipeline
    /// observer borrows its embedded channel.
    ///
    /// ```zig
    /// var observations: Observations = undefined;
    /// try observations.init(liveness);
    /// ```
    pub fn init(observations: *Observations, liveness: Liveness) !void {
        observations.* = .{
            .pipeline_value = .{},
            .channel = undefined,
        };
        observations.channel.init(.{
            .context = liveness.context,
            .is_live = liveness.is_live,
        });
        try observations.pipeline_value.add(observations.channel.observer());
    }

    /// Closes delivery after all publishers have stopped.
    ///
    /// ```zig
    /// observations.close(io);
    /// ```
    pub fn close(observations: *Observations, io: Io) void {
        observations.channel.close(io);
    }

    /// Waits for the next queued event whose credential remains live.
    ///
    /// ```zig
    /// const event = try observations.receive(io);
    /// ```
    pub fn receive(observations: *Observations, io: Io) anyerror!middleware.Event {
        return observations.channel.receive(io);
    }

    /// Borrows the immutable publication pipeline used by active tunnels.
    ///
    /// ```zig
    /// const pipeline = observations.pipeline();
    /// ```
    pub fn pipeline(observations: *const Observations) *const middleware.Pipeline {
        return &observations.pipeline_value;
    }

    /// Returns a lock-free snapshot of bounded queue behavior.
    ///
    /// ```zig
    /// const snapshot = observations.metrics();
    /// ```
    pub fn metrics(observations: *const Observations) observation_queue.Metrics {
        return observations.channel.metrics();
    }
};

const LivenessCapture = struct {
    credential: identity.Credential,

    fn contains(context: *anyopaque, credential: *const identity.Credential) bool {
        const capture: *const LivenessCapture = @ptrCast(@alignCast(context));

        return std.meta.eql(capture.credential, credential.*);
    }
};

test "published observations traverse the owned channel exactly once" {
    const io = std.testing.io;
    var capture: LivenessCapture = .{ .credential = .{
        .pane_id = @enumFromInt(7),
        .pane_generation = 2,
        .token = .{0x5a} ** identity.token_bytes,
    } };
    defer std.crypto.secureZero(u8, &capture.credential.token);
    var observations: Observations = undefined;
    try observations.init(.{ .context = &capture, .is_live = LivenessCapture.contains });
    defer observations.close(io);
    var expected: middleware.Event = .{
        .credential = capture.credential,
        .provider = .claude,
        .phase = .request_started,
        .protocol = .http11,
        .connection_id = 11,
        .observed_at_ms = 42,
    };
    defer std.crypto.secureZero(u8, &expected.credential.token);

    observations.pipeline().publish(io, expected);

    try std.testing.expectEqual(@as(u64, 1), observations.metrics().queued);
    var actual = try observations.receive(io);
    defer std.crypto.secureZero(u8, &actual.credential.token);
    try std.testing.expect(std.meta.eql(expected, actual));
    try std.testing.expectEqual(@as(u64, 0), observations.metrics().queued);
}
