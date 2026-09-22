//! Semantic host-sound values and local playback policy.

const client = @import("telar-client");
const std = @import("std");

test "sound configuration can disable each transition independently" {
    const configuration: client.SoundPolicy = .{ .ready = false };

    try std.testing.expect(!configuration.allows(.ready));
    try std.testing.expect(configuration.allows(.needs_input));
    try std.testing.expect(!(client.SoundPolicy{ .enabled = false }).allows(.needs_input));
}
