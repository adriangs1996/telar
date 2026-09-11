//! Observation pipeline and bounded delivery channel owned as one component.

const std = @import("std");
const identity = @import("../identity.zig");
const middleware = @import("../middleware.zig");
const observation_queue = @import("../observation_queue.zig");

pub const Io = std.Io;

pub const Liveness = @import("Liveness.zig");

pub const Observations = @import("Observations.zig");

const LivenessCapture = @import("LivenessCapture.zig");

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
        .dialect = .anthropic_messages,
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
