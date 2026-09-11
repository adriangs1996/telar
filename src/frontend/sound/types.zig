//! Semantic host-sound values and local playback policy.

const Config = @import("Config.zig");
const std = @import("std");

test "sound configuration can disable each transition independently" {
    const configuration: Config = .{ .ready = false };

    try std.testing.expect(!configuration.allows(.ready));
    try std.testing.expect(configuration.allows(.needs_input));
    try std.testing.expect(!(Config{ .enabled = false }).allows(.needs_input));
}
