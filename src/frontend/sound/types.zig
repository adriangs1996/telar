//! Semantic host-sound values and local playback policy.

const data = @import("model");
const std = @import("std");

test "sound configuration can disable each transition independently" {
    const configuration: data.SoundPolicy = .{ .ready = false };

    try std.testing.expect(!configuration.allows(.ready));
    try std.testing.expect(configuration.allows(.needs_input));
    try std.testing.expect(!(data.SoundPolicy{ .enabled = false }).allows(.needs_input));
}
